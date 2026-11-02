use crate::history::History;
use crate::library;
use crate::settings::{tr, Settings};
use chrono::Local;
use rand::seq::SliceRandom;
use serde::{Deserialize, Serialize};
use serde_json::json;
use std::collections::HashMap;
use std::fs;
use std::path::PathBuf;
use std::sync::mpsc::{self, Sender};
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::{Duration, Instant};
use tauri::{AppHandle, Emitter, Manager};

pub const MAX_HP: i64 = 100;

#[derive(Serialize, Deserialize, Clone)]
pub struct LogEntry {
    /// RFC 3339, local time.
    pub date: String,
    pub delta: i64,
    pub reason: String,
}

/// Runtime state that survives restarts (state.json).
#[derive(Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct PetData {
    pub hp: i64,
    pub log: Vec<LogEntry>,
    /// Some input happened during tonight's curfew window.
    pub violated_tonight: bool,
    /// The last curfew end that was judged for the good-night heal (RFC 3339).
    pub last_settled_curfew_end: Option<String>,
}

impl Default for PetData {
    fn default() -> Self {
        PetData { hp: MAX_HP, log: vec![], violated_tonight: false, last_settled_curfew_end: None }
    }
}

/// Everything shared between the windows, the tray, the rules thread and the attack thread.
pub struct Shared {
    pub data_dir: PathBuf,
    pub library_root: PathBuf,
    pub settings: Mutex<Settings>,
    pub pet: Mutex<PetData>,
    pub history: Mutex<History>,
    attacks: Sender<Attack>,
    /// Region of the pet window that takes the mouse (logical px, window-relative); elsewhere
    /// clicks go to whatever is behind the window.
    pub hit_rect: Mutex<Option<[f64; 4]>>,
    /// Last window move, saved once the window has been still for a moment.
    pub pending_move: Mutex<Option<(Instant, i32, i32)>>,
    /// What's being generated right now (shown in the settings window), if anything.
    pub busy: Mutex<Option<String>>,
}

pub type State = Arc<Shared>;

#[derive(Clone, Copy, PartialEq, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum AttackStyle {
    Lightning,
    Slap,
    Can,
}

impl AttackStyle {
    /// The configured style; "random" picks one per attack.
    fn current(settings: &Settings) -> Self {
        match settings.string("attackStyle").as_deref() {
            Some("slap") => Self::Slap,
            Some("can") => Self::Can,
            Some("random") => *[Self::Lightning, Self::Slap, Self::Can].choose(&mut rand::thread_rng()).unwrap(),
            _ => Self::Lightning,
        }
    }

    /// Max hits per combo; small damage gets fewer hits (never a 0-damage hit).
    fn hits(self) -> i64 {
        match self {
            Self::Slap => 6,
            _ => 3,
        }
    }

    /// Delay before the first hit, time between hits, and time from a hit's start until it lands.
    /// Same timings as the macOS version.
    fn timing(self) -> (f64, f64, f64) {
        match self {
            Self::Lightning => (0.6, 0.8, 0.08),
            Self::Slap => (0.15, 0.38, 0.12),
            Self::Can => (0.5, 0.9, 0.38),
        }
    }
}

struct Attack {
    amount: i64,
    reason: String,
    style: AttackStyle,
    preview: bool,
}

#[derive(Serialize, Clone)]
#[serde(rename_all = "camelCase")]
pub struct StatePayload {
    hp: i64,
    max_hp: i64,
    english: bool,
    busy: Option<String>,
    /// Selected art per slot folder ("pet/normal", "fx/cloud", ...): absolute file paths.
    art: HashMap<String, Option<String>>,
}

impl Shared {
    pub fn new(data_dir: PathBuf, app: AppHandle) -> State {
        let settings = Settings::load(&data_dir);
        let pet = fs::read(data_dir.join("state.json"))
            .ok()
            .and_then(|d| serde_json::from_slice(&d).ok())
            .unwrap_or_default();
        let history = History::load(&data_dir);
        let (tx, rx) = mpsc::channel::<Attack>();
        let shared = Arc::new(Shared {
            library_root: data_dir.join("Library"),
            data_dir,
            settings: Mutex::new(settings),
            pet: Mutex::new(pet),
            history: Mutex::new(history),
            attacks: tx,
            hit_rect: Mutex::new(None),
            pending_move: Mutex::new(None),
            busy: Mutex::new(None),
        });
        // Attacks play one at a time, in order, on their own thread.
        thread::spawn(move || {
            for attack in rx {
                run_attack(&app, attack);
            }
        });
        shared
    }

    pub fn english(&self) -> bool {
        self.settings.lock().unwrap().english()
    }

    pub fn hp(&self) -> i64 {
        self.pet.lock().unwrap().hp
    }

    pub fn save_pet(&self) {
        let pet = self.pet.lock().unwrap();
        if let Ok(data) = serde_json::to_vec_pretty(&*pet) {
            let _ = fs::write(self.data_dir.join("state.json"), data);
        }
    }

    pub fn payload(&self) -> StatePayload {
        let settings = self.settings.lock().unwrap();
        let art = library::SLOTS
            .iter()
            .map(|(folder, _)| {
                let path = library::selected(&self.library_root, &settings, folder);
                (folder.to_string(), path.map(|p| p.to_string_lossy().into_owned()))
            })
            .collect();
        let busy = self.busy.lock().unwrap().clone();
        StatePayload { hp: self.hp(), max_hp: MAX_HP, english: settings.english(), busy, art }
    }
}

fn state(app: &AppHandle) -> State {
    app.state::<State>().inner().clone()
}

/// Tell every window (and the tray) that something changed.
pub fn broadcast(app: &AppHandle) {
    let _ = app.emit("state", state(app).payload());
    crate::tray::refresh(app);
}

pub fn say(app: &AppHandle, text: &str, seconds: f64) {
    let _ = app.emit("speech", json!({ "text": text, "seconds": seconds }));
}

/// Queue an attack combo; HP drops hit by hit. `preview` plays it without costing HP.
pub fn damage(app: &AppHandle, amount: i64, reason: String, preview: bool) {
    let s = state(app);
    if amount <= 0 || s.hp() <= 0 {
        return;
    }
    let style = AttackStyle::current(&s.settings.lock().unwrap());
    let _ = s.attacks.send(Attack { amount, reason, style, preview });
}

fn run_attack(app: &AppHandle, attack: Attack) {
    let s = state(app);
    if s.hp() <= 0 {
        return;
    }
    let (windup, interval, impact) = attack.style.timing();
    say(app, &attack.reason, 6.0);
    let _ = app.emit("attack", json!({ "style": attack.style, "active": true }));
    sleep(windup);

    let hits = attack.style.hits().min(attack.amount);
    let mut dealt = 0;
    for i in 0..hits {
        let part = attack.amount / hits + if i < attack.amount % hits { 1 } else { 0 };
        let real = if attack.preview { part } else { part.min(s.hp()) };
        if real <= 0 {
            break;
        }
        let _ = app.emit("hit", json!({ "amount": real, "style": attack.style, "index": i }));
        sleep(impact);
        if !attack.preview {
            set_hp(app, s.hp() - real);
        }
        dealt += real;
        sleep(interval - impact);
    }
    sleep(0.3);
    let _ = app.emit("attack", json!({ "style": attack.style, "active": false }));

    if attack.preview {
        return;
    }
    record(&s, -dealt, &attack.reason);
    if s.hp() <= 0 {
        let en = s.english();
        say(app, &tr(en, "我被你熬倒了… 😵 按时睡一觉我才能复活", "You wore me out… 😵 Get a proper night's sleep to revive me"), 8.0);
    }
}

pub fn heal(app: &AppHandle, amount: i64, reason: &str) {
    let s = state(app);
    let hp = s.hp();
    if amount <= 0 || hp >= MAX_HP {
        return;
    }
    let real = amount.min(MAX_HP - hp);
    set_hp(app, hp + real);
    let _ = app.emit("heal", json!({ "amount": real }));
    record(&s, real, reason);
    say(app, reason, 6.0);
}

fn set_hp(app: &AppHandle, hp: i64) {
    let s = state(app);
    let hp = hp.clamp(0, MAX_HP);
    s.pet.lock().unwrap().hp = hp;
    s.save_pet();
    s.history.lock().unwrap().record(hp);
    broadcast(app);
}

fn record(s: &Shared, delta: i64, reason: &str) {
    {
        let mut pet = s.pet.lock().unwrap();
        pet.log.insert(0, LogEntry { date: Local::now().to_rfc3339(), delta, reason: reason.to_owned() });
        pet.log.truncate(200);
    }
    s.save_pet();
}

pub fn test_reason(en: bool) -> String {
    tr(en, "测试攻击！这就是熬夜的下场 😈", "Test attack! This is what staying up late gets you 😈")
}

pub fn heal_reason(en: bool) -> String {
    tr(en, "满血复活！这次要好好表现哦", "Fully revived! Behave this time")
}

/// Double-click: a random line that fits the pet's condition.
pub fn poke(app: &AppHandle) {
    let s = state(app);
    let en = s.english();
    let hp = s.hp();
    let lines: &[&str] = match (hp <= 0, hp < 30, en) {
        (true, _, true) => &["…(out cold)", "Let me sleep 💤"],
        (true, _, false) => &["……（昏迷中）", "让我睡会儿 💤"],
        (_, true, true) => &["I can't hold on much longer. Bed early tonight?", "HP so low… 😣", "Please, no more late nights"],
        (_, true, false) => &["我快撑不住了，今晚早点睡好吗？", "HP 好低… 😣", "别再熬夜了求你了"],
        (_, _, true) => &["Stay disciplined today!", "I'm watching you 👀", "Drink water, get up and stretch~", "Past midnight means bedtime"],
        (_, _, false) => &["今天也要自律哦！", "我在盯着你 👀", "记得喝水、起来走走～", "过了 12 点就该睡觉啦"],
    };
    say(app, lines.choose(&mut rand::thread_rng()).unwrap(), 3.0);
}

fn sleep(seconds: f64) {
    if seconds > 0.0 {
        thread::sleep(Duration::from_secs_f64(seconds));
    }
}
