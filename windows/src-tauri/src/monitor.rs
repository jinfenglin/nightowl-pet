use crate::pet::{self, State};
use crate::settings::tr;
use chrono::{DateTime, Duration, Local, TimeZone, Timelike};
use std::thread;
use tauri::{AppHandle, Manager};

/// Polls user activity once a minute and turns bad habits into damage (same rules as macOS):
///  - Late night: any input during the curfew window costs HP every minute.
///  - Long sitting: continuous use beyond the limit costs HP until a real break is taken.
///  - Good night: if a whole curfew window passes without a violation, heal at its end.
pub fn start(app: AppHandle) {
    thread::spawn(move || {
        let mut monitor = Monitor { streak_start: None, last_tick: Local::now() };
        loop {
            monitor.tick(&app);
            thread::sleep(std::time::Duration::from_secs(60));
        }
    });
}

struct Monitor {
    streak_start: Option<DateTime<Local>>,
    last_tick: DateTime<Local>,
}

/// Seconds since the last keyboard/mouse input (GetLastInputInfo on Windows). No permission needed.
fn idle_seconds() -> f64 {
    user_idle::UserIdle::get_time().map(|t| t.as_seconds() as f64).unwrap_or(0.0)
}

struct Curfew {
    start: i64,
    end: i64,
}

impl Curfew {
    fn enabled(&self) -> bool {
        self.start != self.end
    }

    fn contains(&self, now: DateTime<Local>) -> bool {
        if !self.enabled() {
            return false;
        }
        let m = (now.hour() * 60 + now.minute()) as i64;
        if self.start < self.end { m >= self.start && m < self.end } else { m >= self.start || m < self.end }
    }

    /// The latest curfew end time that is <= now.
    fn most_recent_end(&self, now: DateTime<Local>) -> Option<DateTime<Local>> {
        if !self.enabled() {
            return None;
        }
        let date = now.date_naive();
        let naive = date.and_hms_opt((self.end / 60) as u32, (self.end % 60) as u32, 0)?;
        let mut end = Local.from_local_datetime(&naive).earliest()?;
        if end > now {
            end -= Duration::days(1);
        }
        Some(end)
    }
}

impl Monitor {
    fn tick(&mut self, app: &AppHandle) {
        let s: State = app.state::<State>().inner().clone();
        let now = Local::now();
        let idle = idle_seconds();
        let gap = (now - self.last_tick).num_seconds() as f64; // large after system sleep
        self.last_tick = now;

        let (curfew, threshold, late_damage, sitting, break_minutes, limit, sit_damage, en) = {
            let st = s.settings.lock().unwrap();
            (
                Curfew { start: st.int("curfewStart"), end: st.int("curfewEnd") },
                st.int("idleThreshold") as f64,
                st.int("lateNightDamage"),
                st.bool("sittingEnabled"),
                st.int("breakMinutes"),
                st.int("sittingLimit"),
                st.int("sittingDamage"),
                st.english(),
            )
        };
        let active = idle < threshold;

        let hp = s.hp();
        s.history.lock().unwrap().record(hp); // so a day without HP changes still gets a sample
        self.settle_nights(app, &s, &curfew, now);

        if curfew.contains(now) {
            self.streak_start = None;
            if active {
                let clock = now.format("%H:%M");
                pet::damage(
                    app,
                    late_damage,
                    tr(en, &format!("已经 {clock} 了还在用电脑！快去睡觉！"), &format!("It's {clock} and you're still on the computer! Go to bed!")),
                    false,
                );
                s.pet.lock().unwrap().violated_tonight = true;
                s.save_pet();
            }
            return;
        }

        if !sitting {
            self.streak_start = None;
            return;
        }
        let break_seconds = (break_minutes * 60) as f64;
        if idle >= break_seconds || gap >= break_seconds {
            self.streak_start = None;
        }
        if !active {
            return;
        }
        let start = *self.streak_start.get_or_insert(now);
        let minutes = (now - start).num_minutes();
        if minutes >= limit {
            pet::damage(
                app,
                sit_damage,
                tr(
                    en,
                    &format!("已经连续用电脑 {minutes} 分钟了，起来活动 {break_minutes} 分钟吧！"),
                    &format!("{minutes} minutes straight at the computer. Get up and move for {break_minutes} minutes!"),
                ),
                false,
            );
        }
    }

    /// Reward each curfew window that ended without a violation. Robust to the app being closed
    /// or the computer sleeping through the night.
    fn settle_nights(&self, app: &AppHandle, s: &State, curfew: &Curfew, now: DateTime<Local>) {
        let Some(end) = curfew.most_recent_end(now) else { return };
        // Settings before pet: the same lock order as everywhere else.
        let (heal, en) = {
            let st = s.settings.lock().unwrap();
            (st.int("goodNightHeal"), st.english())
        };
        let (first_time, violated) = {
            let mut pet = s.pet.lock().unwrap();
            let last = pet.last_settled_curfew_end.as_deref().and_then(|t| DateTime::parse_from_rfc3339(t).ok());
            if let Some(last) = last {
                if end <= last {
                    return;
                }
            }
            pet.last_settled_curfew_end = Some(end.to_rfc3339());
            let violated = pet.violated_tonight;
            pet.violated_tonight = false;
            (last.is_none(), violated)
        };
        s.save_pet();
        if first_time || violated {
            return; // first launch: nothing to judge yet
        }
        pet::heal(app, heal, &tr(en, "昨晚按时休息，HP 恢复！☀️", "You slept on time last night. HP restored! ☀️"));
    }
}
