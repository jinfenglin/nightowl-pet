use crate::ai;
use crate::library;
use crate::prompts::{self, EFFECTS, POSES};
use crate::settings::{tr, Settings};
use base64::{engine::general_purpose::STANDARD as B64, Engine};
use chrono::Local;
use serde_json::{json, Map, Value};
use std::fs;
use std::path::Path;

/// One JSON file with the settings, prompts and the selected art (base64 PNG). Same format as the
/// macOS version ("deskpet-config", version 1), so configs move between the two.
const FORMAT: &str = "deskpet-config";
const VERSION: i64 = 1;

/// Rules, attack style and provider/model. Proxy, language, HP and window position stay local.
const SETTINGS: &[&str] = &[
    "curfewStart", "curfewEnd", "lateNightDamage", "idleThreshold", "sittingEnabled", "sittingLimit",
    "sittingDamage", "breakMinutes", "goodNightHeal", "attackStyle", "provider", "apiBase", "imageModel", "geminiModel",
];
const SECRETS: &[&str] = &["apiKey", "geminiKey"];

fn png_of(path: &std::path::Path) -> Option<Vec<u8>> {
    let bytes = fs::read(path).ok()?;
    if bytes.starts_with(b"\x89PNG") {
        return Some(bytes);
    }
    ai::png(&image::load_from_memory(&bytes).ok()?).ok()
}

pub fn export(settings: &Settings, library_root: &Path, include_secrets: bool) -> Result<Vec<u8>, String> {
    let mut values = Map::new();
    for key in SETTINGS {
        values.insert(key.to_string(), settings.get(key));
    }
    for (folder, _) in POSES.iter().chain(EFFECTS) {
        values.insert(prompts::key(folder), json!(prompts::editable(&settings, folder)));
    }
    values.insert(prompts::FX_STYLE_KEY.into(), json!(prompts::fx_style(&settings)));
    if include_secrets {
        for key in SECRETS {
            if let Some(v) = settings.string(key).filter(|v| !v.trim().is_empty()) {
                values.insert(key.to_string(), json!(v));
            }
        }
    }
    let art = |list: &[(&str, &str)]| -> Map<String, Value> {
        list.iter()
            .filter_map(|(folder, raw)| {
                let png = png_of(&library::selected(library_root, settings, folder)?)?;
                Some((raw.to_string(), json!(B64.encode(png))))
            })
            .collect()
    };
    let root = json!({
        "format": FORMAT,
        "version": VERSION,
        "exportedAt": Local::now().to_rfc3339(),
        "settings": values,
        "images": art(POSES),
        "effects": art(EFFECTS),
    });
    serde_json::to_vec_pretty(&root).map_err(|e| e.to_string())
}

/// Replaces the settings in the file and the whole art set: images in the file become new library
/// files and are selected; slots missing from the file go back to the filter / drawn version
/// (their old files stay in the library). API keys are only overwritten when the file has them.
/// Returns (settings applied, images imported).
pub fn import(settings: &mut Settings, library_root: &Path, data: &[u8]) -> Result<(usize, usize), String> {
    let en = settings.english();
    let root: Value = serde_json::from_slice(data).map_err(|_| tr(en, "这不是 DeskPet 配置文件", "This isn't a DeskPet config file"))?;
    if root["format"] != FORMAT {
        return Err(tr(en, "这不是 DeskPet 配置文件", "This isn't a DeskPet config file"));
    }
    let version = root["version"].as_i64().unwrap_or(0);
    if version > VERSION {
        return Err(tr(en, &format!("配置文件版本 {version} 比当前 App 新，请先更新 DeskPet"),
            &format!("Config version {version} is newer than this app. Please update DeskPet first")));
    }

    let allowed: Vec<String> = SETTINGS.iter().chain(SECRETS).map(|k| k.to_string()).chain(prompts::exported_keys()).collect();
    let mut setting_count = 0;
    if let Some(values) = root["settings"].as_object() {
        for (key, value) in values {
            if allowed.contains(key) && (value.is_string() || value.is_number() || value.is_boolean()) {
                settings.set(key, value.clone());
                setting_count += 1;
            }
        }
    }

    let mut image_count = 0;
    for (section, list) in [("images", POSES), ("effects", EFFECTS)] {
        for (folder, raw) in list {
            let png = root[section][raw]
                .as_str()
                .and_then(|b64| B64.decode(b64).ok())
                .and_then(|bytes| image::load_from_memory(&bytes).ok())
                .and_then(|img| ai::png(&img).ok());
            match png.and_then(|png| library::add_png(library_root, folder, &png, None)) {
                Some(name) => {
                    library::select(settings, folder, Some(&name));
                    image_count += 1;
                }
                None => library::select(settings, folder, None),
            }
        }
    }
    Ok((setting_count, image_count))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::library;

    fn temp_dir(name: &str) -> std::path::PathBuf {
        let dir = std::env::temp_dir().join(format!("deskpet-test-{name}-{}", std::process::id()));
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(&dir).unwrap();
        dir
    }

    fn tiny_png() -> Vec<u8> {
        ai::png(&image::DynamicImage::new_rgba8(4, 4)).unwrap()
    }

    #[test]
    fn round_trip_keeps_settings_prompts_and_art() {
        let a = temp_dir("export");
        let mut settings = Settings::load(&a);
        settings.set("curfewStart", json!(1380));
        settings.set("fxPrompt.can", json!("A blue can"));
        settings.set("apiKey", json!("sk-secret"));
        let root = a.join("Library");
        let name = library::add_png(&root, "pet/hurt", &tiny_png(), None).unwrap();
        library::select(&mut settings, "pet/hurt", Some(&name));

        let without_keys = export(&settings, &root, false).unwrap();
        assert!(!String::from_utf8_lossy(&without_keys).contains("sk-secret"));
        let data = export(&settings, &root, true).unwrap();

        let b = temp_dir("import");
        let mut target = Settings::load(&b);
        target.set("apiKey", json!("keep-me"));
        let (count, images) = import(&mut target, &b.join("Library"), &data).unwrap();
        assert!(count > 20, "settings applied: {count}");
        assert_eq!(images, 1);
        assert_eq!(target.int("curfewStart"), 1380);
        assert_eq!(target.string("fxPrompt.can").as_deref(), Some("A blue can"));
        assert_eq!(target.string("apiKey").as_deref(), Some("sk-secret"));
        assert!(library::selected(&b.join("Library"), &target, "pet/hurt").is_some());
        assert!(library::selected(&b.join("Library"), &target, "pet/normal").is_none());
    }

    #[test]
    fn imports_a_mac_style_file() {
        // The macOS app writes decimals for some numbers and camelCase effect names.
        let png = B64.encode(tiny_png());
        let data = serde_json::to_vec(&json!({
            "format": "deskpet-config", "version": 1,
            "settings": { "idleThreshold": 120.0, "sittingEnabled": false, "attackStyle": "can", "unknown": 1 },
            "images": { "normal": png },
            "effects": { "throwerIdle": png },
        }))
        .unwrap();
        let dir = temp_dir("mac");
        let mut settings = Settings::load(&dir);
        settings.set("apiKey", json!("keep-me"));
        let (count, images) = import(&mut settings, &dir.join("Library"), &data).unwrap();
        assert_eq!((count, images), (3, 2));
        assert_eq!(settings.int("idleThreshold"), 120);
        assert!(!settings.bool("sittingEnabled"));
        assert_eq!(settings.string("apiKey").as_deref(), Some("keep-me"));
        assert!(library::selected(&dir.join("Library"), &settings, "fx/thrower-idle").is_some());
    }

    #[test]
    fn rejects_other_files_and_newer_versions() {
        let dir = temp_dir("bad");
        let mut settings = Settings::load(&dir);
        assert!(import(&mut settings, &dir, b"{\"hello\": 1}").is_err());
        assert!(import(&mut settings, &dir, b"not json").is_err());
        let newer = serde_json::to_vec(&json!({ "format": "deskpet-config", "version": 2 })).unwrap();
        assert!(import(&mut settings, &dir, &newer).is_err());
    }
}
