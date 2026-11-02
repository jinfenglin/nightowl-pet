use serde_json::{json, Map, Value};
use std::fs;
use std::path::{Path, PathBuf};

/// User settings, saved as settings.json in the data folder. Key names match the macOS
/// version's preferences so the two stay recognizable (and config files can be shared later).
pub struct Settings {
    path: PathBuf,
    values: Map<String, Value>,
}

/// Defaults, in minutes since midnight for times.
const DEFAULTS: &[(&str, fn() -> Value)] = &[
    ("curfewStart", || json!(0)),        // 00:00
    ("curfewEnd", || json!(6 * 60)),     // 06:00
    ("lateNightDamage", || json!(2)),    // HP per active minute after curfew
    ("idleThreshold", || json!(120)),    // seconds without input => away
    ("sittingEnabled", || json!(true)),
    ("sittingLimit", || json!(90)),      // minutes of continuous use
    ("sittingDamage", || json!(1)),      // HP per minute beyond the limit
    ("breakMinutes", || json!(5)),       // away this long resets the streak
    ("goodNightHeal", || json!(30)),     // HP restored after a clean night
    ("attackStyle", || json!("lightning")),
    ("language", || json!("system")),
    ("provider", || json!("openAI")),
    ("apiBase", || json!("https://api.openai.com/v1")),
    ("imageModel", || json!("gpt-image-1")),
    ("geminiModel", || json!("gemini-2.5-flash-image")),
];

impl Settings {
    pub fn load(dir: &Path) -> Self {
        let path = dir.join("settings.json");
        let values = fs::read(&path)
            .ok()
            .and_then(|data| serde_json::from_slice::<Map<String, Value>>(&data).ok())
            .unwrap_or_default();
        Settings { path, values }
    }

    pub fn get(&self, key: &str) -> Value {
        if let Some(v) = self.values.get(key) {
            return v.clone();
        }
        DEFAULTS.iter().find(|(k, _)| *k == key).map(|(_, f)| f()).unwrap_or(Value::Null)
    }

    /// Configs exported by the macOS app may store whole numbers as decimals (120.0).
    pub fn int(&self, key: &str) -> i64 {
        let v = self.get(key);
        v.as_i64().or_else(|| v.as_f64().map(|f| f.round() as i64)).unwrap_or(0)
    }

    pub fn bool(&self, key: &str) -> bool {
        self.get(key).as_bool().unwrap_or(false)
    }

    pub fn string(&self, key: &str) -> Option<String> {
        self.get(key).as_str().map(str::to_owned)
    }

    /// Setting a key to null removes it (falls back to the default).
    pub fn set(&mut self, key: &str, value: Value) {
        if value.is_null() {
            self.values.remove(key);
        } else {
            self.values.insert(key.to_owned(), value);
        }
        self.save();
    }

    /// Everything the settings window needs: stored values plus defaults.
    pub fn all(&self) -> Map<String, Value> {
        let mut out = self.values.clone();
        for (k, f) in DEFAULTS {
            out.entry(k.to_string()).or_insert_with(f);
        }
        out
    }

    fn save(&self) {
        if let Ok(data) = serde_json::to_vec_pretty(&self.values) {
            let tmp = self.path.with_extension("json.tmp");
            if fs::write(&tmp, data).is_ok() {
                let _ = fs::rename(&tmp, &self.path);
            }
        }
    }

    /// Chinese or English, for UI text generated in Rust (speech, menus).
    pub fn english(&self) -> bool {
        match self.string("language").as_deref() {
            Some("zh") => false,
            Some("en") => true,
            _ => !sys_locale::get_locale().unwrap_or_default().starts_with("zh"),
        }
    }
}

/// Pick the string for the current language.
pub fn tr(english: bool, zh: &str, en: &str) -> String {
    if english { en.to_owned() } else { zh.to_owned() }
}
