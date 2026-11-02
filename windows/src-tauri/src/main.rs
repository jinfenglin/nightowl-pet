// No console window in release builds on Windows.
#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

mod ai;
mod commands;
mod config;
mod generate;
mod history;
mod library;
mod monitor;
mod pet;
mod prompts;
mod settings;
mod tray;
mod windows;

use pet::{Shared, State};
use tauri::{Manager, WindowEvent};
use tauri_plugin_autostart::MacosLauncher;

/// %APPDATA%\DeskPet on Windows. When run on macOS for development it uses a separate
/// "DeskPet-Tauri" folder, so it never touches the native macOS app's data.
fn data_dir(app: &tauri::AppHandle) -> std::path::PathBuf {
    let base = app.path().data_dir().expect("no data directory");
    let name = if cfg!(target_os = "macos") { "DeskPet-Tauri" } else { "DeskPet" };
    let dir = base.join(name);
    let _ = std::fs::create_dir_all(&dir);
    dir
}

fn main() {
    tauri::Builder::default()
        // A second launch just opens Settings instead of adding another pet.
        .plugin(tauri_plugin_single_instance::init(|app, _, _| windows::open_settings(app)))
        .plugin(tauri_plugin_autostart::init(MacosLauncher::LaunchAgent, None))
        .plugin(tauri_plugin_dialog::init())
        .plugin(tauri_plugin_opener::init())
        .plugin(tauri_plugin_clipboard_manager::init())
        .setup(|app| {
            #[cfg(target_os = "macos")]
            app.set_activation_policy(tauri::ActivationPolicy::Accessory);

            let handle = app.handle().clone();
            let shared: State = Shared::new(data_dir(&handle), handle.clone());
            let _ = app.asset_protocol_scope().allow_directory(&shared.data_dir, true);
            if let Ok(resources) = app.path().resource_dir() {
                let mut settings = shared.settings.lock().unwrap();
                library::install_defaults(&shared.library_root, &resources.join("defaults"), &mut settings);
            }
            let hp = shared.hp();
            shared.history.lock().unwrap().record(hp);
            app.manage(shared);

            tray::create(&handle)?;
            windows::place_pet(&handle);
            windows::start_mouse_passthrough(handle.clone());
            monitor::start(handle);
            Ok(())
        })
        .on_menu_event(tray::handle)
        .on_window_event(|window, event| {
            if window.label() == "pet" {
                if let WindowEvent::Moved(position) = event {
                    windows::pet_moved(window.app_handle(), *position);
                }
            }
        })
        .invoke_handler(tauri::generate_handler![
            commands::get_state,
            commands::get_settings,
            commands::set_setting,
            commands::get_library,
            commands::select_asset,
            commands::import_asset,
            commands::reveal_asset,
            commands::delete_asset,
            commands::test_attack,
            commands::full_heal,
            commands::poke,
            commands::get_log,
            commands::get_history,
            commands::get_autostart,
            commands::set_autostart,
            commands::set_hit_rect,
            commands::show_context_menu,
            commands::open_settings,
            commands::log_js,
            commands::get_prompts,
            commands::copy_prompt,
            commands::create_character,
            commands::generate_poses,
            commands::generate_effects,
            commands::export_config,
            commands::import_config,
        ])
        .run(tauri::generate_context!())
        .expect("error while running DeskPet");
}
