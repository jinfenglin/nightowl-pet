use crate::pet::State;
use crate::settings::tr;
use serde_json::json;
use std::thread;
use std::time::{Duration, Instant};
use tauri::{AppHandle, Manager, PhysicalPosition, WebviewUrl, WebviewWindowBuilder};

pub fn open_settings(app: &AppHandle) {
    if let Some(w) = app.get_webview_window("settings") {
        let _ = w.show();
        let _ = w.unminimize();
        let _ = w.set_focus();
        return;
    }
    let en = app.state::<State>().english();
    let _ = WebviewWindowBuilder::new(app, "settings", WebviewUrl::App("settings.html".into()))
        .title(tr(en, "DeskPet 设置", "DeskPet Settings"))
        .inner_size(640.0, 720.0)
        .min_inner_size(560.0, 480.0)
        .center()
        .build();
}

/// Retitle open windows after a language change.
pub fn retitle(app: &AppHandle) {
    let en = app.state::<State>().english();
    if let Some(w) = app.get_webview_window("settings") {
        let _ = w.set_title(&tr(en, "DeskPet 设置", "DeskPet Settings"));
    }
}

/// Restore the saved position if it's still on a screen; otherwise bottom-right of the main screen.
pub fn place_pet(app: &AppHandle) {
    let Some(w) = app.get_webview_window("pet") else { return };
    let s = app.state::<State>();
    let saved = {
        let st = s.settings.lock().unwrap();
        st.get("window.x").as_i64().zip(st.get("window.y").as_i64())
    };
    let size = w.outer_size().unwrap_or_default();
    let on_screen = |x: i64, y: i64| {
        w.available_monitors().unwrap_or_default().iter().any(|m| {
            let (p, sz) = (m.position(), m.size());
            x >= p.x as i64 - 100 && y >= p.y as i64 && x < (p.x + sz.width as i32) as i64 - 100 && y < (p.y + sz.height as i32) as i64 - 100
        })
    };
    let position = match saved {
        Some((x, y)) if on_screen(x, y) => PhysicalPosition::new(x as i32, y as i32),
        _ => match w.primary_monitor().ok().flatten() {
            Some(m) => {
                let area = m.work_area();
                PhysicalPosition::new(
                    area.position.x + area.size.width as i32 - size.width as i32 - 20,
                    area.position.y + area.size.height as i32 - size.height as i32 - 20,
                )
            }
            None => PhysicalPosition::new(100, 100),
        },
    };
    let _ = w.set_position(position);
    let _ = w.show();
}

pub fn pet_moved(app: &AppHandle, position: PhysicalPosition<i32>) {
    *app.state::<State>().pending_move.lock().unwrap() = Some((Instant::now(), position.x, position.y));
}

/// The pet window is mostly transparent, but on Windows a transparent window still swallows
/// clicks. So let the mouse through except over the pet itself (the rect reported by the page),
/// checking the cursor ~25 times a second. Also saves the window position once a drag settles.
pub fn start_mouse_passthrough(app: AppHandle) {
    thread::spawn(move || {
        let mut passing: Option<bool> = None;
        loop {
            thread::sleep(Duration::from_millis(40));
            let s = app.state::<State>();
            save_settled_move(&s);

            let Some(w) = app.get_webview_window("pet") else { continue };
            if !w.is_visible().unwrap_or(false) {
                continue;
            }
            let rect = *s.hit_rect.lock().unwrap();
            let (Ok(cursor), Ok(origin), Ok(scale)) = (w.cursor_position(), w.outer_position(), w.scale_factor()) else {
                continue;
            };
            let over_pet = rect.is_some_and(|[x, y, width, height]| {
                let (cx, cy) = ((cursor.x - origin.x as f64) / scale, (cursor.y - origin.y as f64) / scale);
                cx >= x && cx <= x + width && cy >= y && cy <= y + height
            });
            if passing != Some(!over_pet) {
                passing = Some(!over_pet);
                let _ = w.set_ignore_cursor_events(!over_pet);
            }
        }
    });
}

fn save_settled_move(s: &State) {
    let mut pending = s.pending_move.lock().unwrap();
    if let Some((at, x, y)) = *pending {
        if at.elapsed() > Duration::from_millis(800) {
            *pending = None;
            drop(pending);
            let mut st = s.settings.lock().unwrap();
            st.set("window.x", json!(x));
            st.set("window.y", json!(y));
        }
    }
}
