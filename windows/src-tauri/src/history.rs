use chrono::{Local, NaiveDate};
use serde::{Deserialize, Serialize};
use std::fs;
use std::path::{Path, PathBuf};

/// Lowest HP seen on one local calendar day (same file format as the macOS version).
#[derive(Serialize, Deserialize, Clone)]
pub struct DailyHP {
    /// "yyyy-MM-dd"
    pub day: String,
    #[serde(rename = "minHP")]
    pub min_hp: i64,
}

/// Daily minimum HP, persisted to hp_history.json.
pub struct History {
    path: PathBuf,
    pub days: Vec<DailyHP>,
}

const KEEP_DAYS: usize = 400;

impl History {
    pub fn load(dir: &Path) -> Self {
        let path = dir.join("hp_history.json");
        let days = fs::read(&path)
            .ok()
            .and_then(|data| serde_json::from_slice(&data).ok())
            .unwrap_or_default();
        History { path, days }
    }

    /// Fold an HP sample into today's minimum; only writes when something changed.
    pub fn record(&mut self, hp: i64) {
        let key = Local::now().format("%Y-%m-%d").to_string();
        if let Some(d) = self.days.iter_mut().find(|d| d.day == key) {
            if hp >= d.min_hp {
                return;
            }
            d.min_hp = hp;
        } else {
            self.days.push(DailyHP { day: key, min_hp: hp });
            self.days.sort_by(|a, b| a.day.cmp(&b.day));
            if self.days.len() > KEEP_DAYS {
                let extra = self.days.len() - KEEP_DAYS;
                self.days.drain(..extra);
            }
        }
        self.save();
    }

    /// Records within the last `count` days, ending today.
    pub fn recent(&self, count: i64) -> Vec<DailyHP> {
        let today = Local::now().date_naive();
        let start = today - chrono::Duration::days(count - 1);
        self.days
            .iter()
            .filter(|d| {
                NaiveDate::parse_from_str(&d.day, "%Y-%m-%d").map(|x| x >= start && x <= today).unwrap_or(false)
            })
            .cloned()
            .collect()
    }

    fn save(&self) {
        if let Ok(data) = serde_json::to_vec_pretty(&self.days) {
            let _ = fs::write(&self.path, data);
        }
    }
}
