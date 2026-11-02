use crate::history::DailyHP;
use crate::prompts::{self, PromptInfo};
use crate::{config, generate};
use tauri_plugin_clipboard_manager::ClipboardExt;
use tauri_plugin_dialog::{MessageDialogButtons, MessageDialogKind};
use crate::library::{self, SlotInfo};
use crate::pet::{self, LogEntry, State, StatePayload, MAX_HP};
use crate::{tray, windows};
use serde_json::{Map, Value};
use tauri::{AppHandle, Manager, State as Managed};
use tauri_plugin_autostart::ManagerExt;
use tauri_plugin_dialog::DialogExt;
use tauri_plugin_opener::OpenerExt;

#[tauri::command]
pub fn get_state(state: Managed<State>) -> StatePayload {
    state.payload()
}

#[tauri::command]
pub fn get_settings(state: Managed<State>) -> Map<String, Value> {
    let mut all = state.settings.lock().unwrap().all();
    all.insert("resolvedEnglish".into(), Value::Bool(state.english()));
    all
}

#[tauri::command]
pub fn set_setting(app: AppHandle, state: Managed<State>, key: String, value: Value) {
    state.settings.lock().unwrap().set(&key, value);
    if key == "language" {
        windows::retitle(&app);
    }
    pet::broadcast(&app);
}

#[tauri::command]
pub fn get_library(state: Managed<State>) -> Vec<SlotInfo> {
    library::info(&state.library_root, &state.settings.lock().unwrap())
}

#[tauri::command]
pub fn select_asset(app: AppHandle, state: Managed<State>, folder: String, name: Option<String>) {
    library::select(&mut state.settings.lock().unwrap(), &folder, name.as_deref());
    pet::broadcast(&app);
}

/// Pick an image file and copy it into the slot's folder; it becomes the current choice.
#[tauri::command]
pub async fn import_asset(app: AppHandle, folder: String) -> Option<String> {
    let picked = app.dialog().file().add_filter("Images", &["png", "jpg", "jpeg", "webp", "gif"]).blocking_pick_file()?;
    let path = picked.into_path().ok()?;
    let state = app.state::<State>();
    let name = library::import(&state.library_root, &folder, &path)?;
    library::select(&mut state.settings.lock().unwrap(), &folder, Some(&name));
    pet::broadcast(&app);
    Some(name)
}

#[tauri::command]
pub fn reveal_asset(app: AppHandle, state: Managed<State>, folder: String, name: Option<String>) {
    let dir = library::directory(&state.library_root, &folder);
    let _ = match name {
        Some(name) => app.opener().reveal_item_in_dir(dir.join(name)),
        None => app.opener().open_path(dir.to_string_lossy(), None::<&str>),
    };
}

#[tauri::command]
pub fn delete_asset(app: AppHandle, state: Managed<State>, folder: String, name: String) {
    library::delete(&state.library_root, &mut state.settings.lock().unwrap(), &folder, &name);
    pet::broadcast(&app);
}

#[tauri::command]
pub fn test_attack(app: AppHandle, state: Managed<State>) {
    pet::damage(&app, 9, pet::test_reason(state.english()), true);
}

#[tauri::command]
pub fn full_heal(app: AppHandle, state: Managed<State>) {
    pet::heal(&app, MAX_HP, &pet::heal_reason(state.english()));
}

#[tauri::command]
pub fn poke(app: AppHandle) {
    pet::poke(&app);
}

#[tauri::command]
pub fn get_log(state: Managed<State>) -> Vec<LogEntry> {
    state.pet.lock().unwrap().log.clone()
}

#[tauri::command]
pub fn get_history(state: Managed<State>) -> Vec<DailyHP> {
    state.history.lock().unwrap().recent(30)
}

#[tauri::command]
pub fn get_autostart(app: AppHandle) -> bool {
    app.autolaunch().is_enabled().unwrap_or(false)
}

#[tauri::command]
pub fn set_autostart(app: AppHandle, enabled: bool) -> Result<(), String> {
    let launcher = app.autolaunch();
    let result = if enabled { launcher.enable() } else { launcher.disable() };
    result.map_err(|e| e.to_string())
}

/// The part of the pet window that should take the mouse (logical px).
#[tauri::command]
pub fn set_hit_rect(state: Managed<State>, x: f64, y: f64, width: f64, height: f64) {
    *state.hit_rect.lock().unwrap() = Some([x, y, width, height]);
}

#[tauri::command]
pub fn show_context_menu(app: AppHandle) {
    if let (Some(w), Ok(menu)) = (app.get_webview_window("pet"), tray::menu(&app)) {
        let _ = w.popup_menu(&menu);
    }
}

#[tauri::command]
pub fn get_prompts(state: Managed<State>) -> Vec<(String, PromptInfo)> {
    prompts::all(&state.settings.lock().unwrap())
}

/// Copy the full prompt for a slot, for use in a web app (Gemini / ChatGPT) without an API key.
#[tauri::command]
pub fn copy_prompt(app: AppHandle, state: Managed<State>, folder: String) {
    let text = prompts::full(&state.settings.lock().unwrap(), &folder);
    let _ = app.clipboard().write_text(text);
}

/// Pick a photo and turn it into the full-HP character (then the other poses, with an API key).
#[tauri::command]
pub async fn create_character(app: AppHandle) {
    let picked = app.dialog().file().add_filter("Images", &["png", "jpg", "jpeg", "webp", "gif"]).blocking_pick_file();
    if let Some(path) = picked.and_then(|p| p.into_path().ok()) {
        generate::create_character(app, path).await;
    }
}

#[tauri::command]
pub async fn generate_poses(app: AppHandle, folders: Vec<String>) {
    generate::generate_poses(app, folders).await;
}

#[tauri::command]
pub async fn generate_effects(app: AppHandle, folders: Vec<String>) {
    generate::generate_effects(app, folders).await;
}

#[tauri::command]
pub async fn export_config(app: AppHandle, include_secrets: bool) -> Result<(), String> {
    let en = app.state::<State>().english();
    let Some(path) = app
        .dialog()
        .file()
        .set_file_name(if en { "DeskPet Config.json" } else { "DeskPet 配置.json" })
        .add_filter("JSON", &["json"])
        .blocking_save_file()
        .and_then(|p| p.into_path().ok())
    else {
        return Ok(());
    };
    let data = {
        let s = app.state::<State>();
        let settings = s.settings.lock().unwrap();
        config::export(&settings, &s.library_root, include_secrets)?
    };
    std::fs::write(&path, data).map_err(|e| e.to_string())?;
    pet::say(&app, if en { "Config exported 📦" } else { "配置已导出 📦" }, 4.0);
    Ok(())
}

#[tauri::command]
pub async fn import_config(app: AppHandle) -> Result<(), String> {
    let en = app.state::<State>().english();
    let l = |zh: &str, english: &str| if en { english.to_owned() } else { zh.to_owned() };
    let Some(path) = app.dialog().file().add_filter("JSON", &["json"]).blocking_pick_file().and_then(|p| p.into_path().ok()) else {
        return Ok(());
    };
    let confirmed = app
        .dialog()
        .message(l("会替换当前的形象、全部状态图、规则和提示词。文件里没有 API Key 时会保留现在的 Key。",
            "This replaces the current character, all poses, rules and prompts. If the file has no API keys, your current keys are kept."))
        .title(l("导入这套配置？", "Import this config?"))
        .kind(MessageDialogKind::Warning)
        .buttons(MessageDialogButtons::OkCancelCustom(l("导入", "Import"), l("取消", "Cancel")))
        .blocking_show();
    if !confirmed {
        return Ok(());
    }
    let data = std::fs::read(&path).map_err(|e| e.to_string())?;
    let (settings, images) = {
        let s = app.state::<State>();
        let mut settings = s.settings.lock().unwrap();
        config::import(&mut settings, &s.library_root, &data)?
    };
    windows::retitle(&app);
    pet::broadcast(&app);
    pet::say(&app, &l(&format!("配置已导入：{settings} 项设置、{images} 张图片 ✅"), &format!("Config imported: {settings} settings, {images} images ✅")), 5.0);
    Ok(())
}

#[tauri::command]
pub fn log_js(message: String) {
    eprintln!("[ui] {message}");
}

#[tauri::command]
pub fn open_settings(app: AppHandle) {
    windows::open_settings(&app);
}
