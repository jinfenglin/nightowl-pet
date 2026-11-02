use crate::settings::Settings;
use chrono::Local;
use serde::Serialize;
use serde_json::json;
use std::fs;
use std::path::{Path, PathBuf};
use std::time::SystemTime;

/// Every kind of art, as (folder inside the library, file-name prefix). Same layout as macOS:
/// `Library/pet/<pose>/` and `Library/fx/<asset>/`.
pub const SLOTS: &[(&str, &str)] = &[
    ("pet/normal", "normal"),
    ("pet/low", "low"),
    ("pet/hurt", "hurt"),
    ("pet/dead", "dead"),
    ("fx/cloud", "cloud"),
    ("fx/thrower-idle", "thrower-idle"),
    ("fx/thrower-toss", "thrower-toss"),
    ("fx/thrower-throw", "thrower-throw"),
    ("fx/can", "can"),
    ("fx/hand", "hand"),
];

const IMAGE_EXTENSIONS: &[&str] = &["png", "jpg", "jpeg", "webp", "gif"];

#[derive(Serialize)]
pub struct FileInfo {
    pub name: String,
    pub path: String,
}

#[derive(Serialize)]
pub struct SlotInfo {
    pub folder: String,
    pub files: Vec<FileInfo>,
    pub selected: Option<String>,
}

fn slot_name(folder: &str) -> Option<&'static str> {
    SLOTS.iter().find(|(f, _)| *f == folder).map(|(_, n)| *n)
}

fn selection_key(folder: &str) -> String {
    format!("asset.selected.{folder}")
}

pub fn directory(root: &Path, folder: &str) -> PathBuf {
    let dir = root.join(folder);
    let _ = fs::create_dir_all(&dir);
    dir
}

/// Image files in the slot's folder, newest first (picks up files dropped in by hand).
pub fn scan(root: &Path, folder: &str) -> Vec<PathBuf> {
    let mut files: Vec<(SystemTime, PathBuf)> = fs::read_dir(directory(root, folder))
        .map(|entries| {
            entries
                .filter_map(|e| e.ok())
                .map(|e| e.path())
                .filter(|p| {
                    let ext = p.extension().and_then(|e| e.to_str()).unwrap_or("").to_lowercase();
                    let hidden = p.file_name().and_then(|n| n.to_str()).map_or(true, |n| n.starts_with('.'));
                    !hidden && IMAGE_EXTENSIONS.contains(&ext.as_str())
                })
                .map(|p| (fs::metadata(&p).and_then(|m| m.modified()).unwrap_or(SystemTime::UNIX_EPOCH), p))
                .collect()
        })
        .unwrap_or_default();
    files.sort_by(|a, b| b.0.cmp(&a.0));
    files.into_iter().map(|(_, p)| p).collect()
}

pub fn selected(root: &Path, settings: &Settings, folder: &str) -> Option<PathBuf> {
    let name = settings.string(&selection_key(folder))?;
    let path = directory(root, folder).join(name);
    path.exists().then_some(path)
}

pub fn select(settings: &mut Settings, folder: &str, name: Option<&str>) {
    settings.set(&selection_key(folder), name.map_or(serde_json::Value::Null, |n| json!(n)));
}

pub fn info(root: &Path, settings: &Settings) -> Vec<SlotInfo> {
    SLOTS
        .iter()
        .map(|(folder, _)| SlotInfo {
            folder: folder.to_string(),
            files: scan(root, folder)
                .into_iter()
                .map(|p| FileInfo {
                    name: p.file_name().unwrap().to_string_lossy().into_owned(),
                    path: p.to_string_lossy().into_owned(),
                })
                .collect(),
            selected: selected(root, settings, folder)
                .map(|p| p.file_name().unwrap().to_string_lossy().into_owned()),
        })
        .collect()
}

/// A fresh path `<name>_<timestamp>[_tag].<ext>` in the slot's folder (never overwrites).
fn new_path(root: &Path, folder: &str, tag: Option<&str>, ext: &str) -> Option<PathBuf> {
    let name = slot_name(folder)?;
    let base = format!("{name}_{}{}", Local::now().format("%Y%m%d-%H%M%S"), tag.map(|t| format!("_{t}")).unwrap_or_default());
    let dir = directory(root, folder);
    let mut target = dir.join(format!("{base}.{ext}"));
    let mut n = 2;
    while target.exists() {
        target = dir.join(format!("{base}-{n}.{ext}"));
        n += 1;
    }
    Some(target)
}

/// Copy an outside image into the slot's folder as `<name>_<timestamp>_import.<ext>`.
pub fn import(root: &Path, folder: &str, source: &Path) -> Option<String> {
    let ext = source.extension().and_then(|e| e.to_str()).unwrap_or("png").to_lowercase();
    if !IMAGE_EXTENSIONS.contains(&ext.as_str()) {
        return None;
    }
    let target = new_path(root, folder, Some("import"), &ext)?;
    fs::copy(source, &target).ok()?;
    Some(target.file_name()?.to_string_lossy().into_owned())
}

/// Save generated / imported PNG data as a new file in the slot's folder.
pub fn add_png(root: &Path, folder: &str, png: &[u8], tag: Option<&str>) -> Option<String> {
    let target = new_path(root, folder, tag, "png")?;
    fs::write(&target, png).ok()?;
    Some(target.file_name()?.to_string_lossy().into_owned())
}

/// Moves the file to the Recycle Bin / Trash (recoverable).
pub fn delete(root: &Path, settings: &mut Settings, folder: &str, name: &str) {
    if settings.string(&selection_key(folder)).as_deref() == Some(name) {
        select(settings, folder, None);
    }
    let _ = trash::delete(directory(root, folder).join(name));
}

/// Built-in art (`defaults/<folder>.png` in the app's resources). Each one is copied into its
/// library folder once, as `<name>_default.png`, and selected if nothing is chosen yet. After that
/// it's an ordinary library file: deselecting or deleting it sticks.
pub fn install_defaults(root: &Path, bundled: &Path, settings: &mut Settings) {
    for (folder, name) in SLOTS {
        let key = format!("asset.defaultInstalled.{folder}");
        let source = bundled.join(format!("{folder}.png"));
        if settings.bool(&key) || !source.exists() {
            continue;
        }
        let target = directory(root, folder).join(format!("{name}_default.png"));
        if target.exists() || fs::copy(&source, &target).is_ok() {
            settings.set(&key, json!(true));
            if settings.string(&selection_key(folder)).is_none() {
                select(settings, folder, Some(&format!("{name}_default.png")));
            }
        }
    }
}
