use crate::pet::{self, State, MAX_HP};
use crate::settings::tr;
use crate::windows;
use serde_json::json;
use tauri::menu::{CheckMenuItem, Menu, MenuEvent, MenuItem, PredefinedMenuItem, Submenu};
use tauri::tray::TrayIconBuilder;
use tauri::{AppHandle, Manager, Wry};

const TRAY_ID: &str = "main";
const STYLES: &[(&str, &str, &str)] = &[
    ("lightning", "⚡️ 雷击", "⚡️ Lightning"),
    ("slap", "🖐️ 连环耳光", "🖐️ Slaps"),
    ("can", "🥫 丢易拉罐", "🥫 Can toss"),
    ("random", "🎲 随机", "🎲 Random"),
];

/// Only the quick, everyday actions; everything else lives in Settings. Shared by the tray icon
/// and the pet's right-click menu.
pub fn menu(app: &AppHandle) -> tauri::Result<Menu<Wry>> {
    let s = app.state::<State>();
    let en = s.english();
    let current = s.settings.lock().unwrap().string("attackStyle").unwrap_or_default();
    let hp = s.hp();
    let visible = app.get_webview_window("pet").and_then(|w| w.is_visible().ok()).unwrap_or(true);

    let styles = Submenu::with_id(app, "styles", tr(en, "攻击特效", "Attack Effect"), true)?;
    for (id, zh, english) in STYLES {
        styles.append(&CheckMenuItem::with_id(app, format!("style:{id}"), tr(en, zh, english), true, current == *id, None::<&str>)?)?;
    }
    Menu::with_items(
        app,
        &[
            &styles,
            &MenuItem::with_id(app, "test", tr(en, "测试一次攻击（不扣血）", "Test Attack (No Damage)"), true, None::<&str>)?,
            &MenuItem::with_id(app, "heal", tr(en, "回满血（作弊）", "Full Heal (Cheat)"), hp < MAX_HP, None::<&str>)?,
            &PredefinedMenuItem::separator(app)?,
            &MenuItem::with_id(app, "settings", tr(en, "设置…", "Settings…"), true, None::<&str>)?,
            &MenuItem::with_id(app, "toggle", if visible { tr(en, "隐藏宠物", "Hide Pet") } else { tr(en, "显示宠物", "Show Pet") }, true, None::<&str>)?,
            &MenuItem::with_id(app, "quit", tr(en, "退出", "Quit"), true, None::<&str>)?,
        ],
    )
}

pub fn create(app: &AppHandle) -> tauri::Result<()> {
    let mut builder = TrayIconBuilder::with_id(TRAY_ID).menu(&menu(app)?).show_menu_on_left_click(true);
    if let Some(icon) = app.default_window_icon() {
        builder = builder.icon(icon.clone());
    }
    builder.build(app)?;
    refresh(app);
    Ok(())
}

/// HP in the tooltip (and next to the icon on macOS); menu rebuilt for language / checkmarks.
pub fn refresh(app: &AppHandle) {
    let Some(tray) = app.tray_by_id(TRAY_ID) else { return };
    let hp = app.state::<State>().hp();
    let label = if hp > 0 { format!("❤️ {hp}") } else { "💀 0".to_owned() };
    let _ = tray.set_tooltip(Some(format!("DeskPet  {label}")));
    #[cfg(target_os = "macos")]
    let _ = tray.set_title(Some(&label));
    if let Ok(menu) = menu(app) {
        let _ = tray.set_menu(Some(menu));
    }
}

pub fn handle(app: &AppHandle, event: MenuEvent) {
    let s = app.state::<State>();
    let en = s.english();
    match event.id().as_ref() {
        id if id.starts_with("style:") => {
            s.settings.lock().unwrap().set("attackStyle", json!(&id["style:".len()..]));
            pet::broadcast(app);
            pet::damage(app, 9, pet::test_reason(en), true);
        }
        "test" => pet::damage(app, 9, pet::test_reason(en), true),
        "heal" => pet::heal(app, MAX_HP, &pet::heal_reason(en)),
        "settings" => windows::open_settings(app),
        "toggle" => {
            if let Some(w) = app.get_webview_window("pet") {
                if w.is_visible().unwrap_or(true) { let _ = w.hide(); } else { let _ = w.show(); }
            }
            refresh(app);
        }
        "quit" => app.exit(0),
        _ => {}
    }
}
