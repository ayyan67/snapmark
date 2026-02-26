use base64::{engine::general_purpose::STANDARD, Engine};
use std::io::Cursor;
use tauri::{Emitter, Manager};
use tauri_plugin_global_shortcut::{GlobalShortcutExt, Shortcut, ShortcutState};

#[tauri::command]
fn read_clipboard_image() -> Result<String, String> {
    let mut clipboard = arboard::Clipboard::new().map_err(|e| e.to_string())?;
    let image_data = clipboard.get_image().map_err(|e| e.to_string())?;

    let img = image::RgbaImage::from_raw(
        image_data.width as u32,
        image_data.height as u32,
        image_data.bytes.into_owned(),
    )
    .ok_or("Failed to create image from clipboard data")?;

    let mut buf = Cursor::new(Vec::new());
    img.write_to(&mut buf, image::ImageFormat::Png)
        .map_err(|e| e.to_string())?;

    Ok(STANDARD.encode(buf.into_inner()))
}

#[tauri::command]
fn write_clipboard_image(base64_png: String) -> Result<(), String> {
    let bytes = STANDARD.decode(&base64_png).map_err(|e| e.to_string())?;
    let img = image::load_from_memory(&bytes).map_err(|e| e.to_string())?;
    let rgba = img.to_rgba8();
    let (width, height) = rgba.dimensions();

    let image_data = arboard::ImageData {
        width: width as usize,
        height: height as usize,
        bytes: std::borrow::Cow::Owned(rgba.into_raw()),
    };

    let mut clipboard = arboard::Clipboard::new().map_err(|e| e.to_string())?;
    clipboard
        .set_image(image_data)
        .map_err(|e| e.to_string())?;

    Ok(())
}

#[tauri::command]
fn save_image(base64_png: String, path: String) -> Result<(), String> {
    let bytes = STANDARD.decode(&base64_png).map_err(|e| e.to_string())?;
    std::fs::write(&path, &bytes).map_err(|e| e.to_string())?;
    Ok(())
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    tauri::Builder::default()
        .plugin(tauri_plugin_clipboard_manager::init())
        .plugin(tauri_plugin_dialog::init())
        .plugin(tauri_plugin_fs::init())
        .plugin(tauri_plugin_shell::init())
        .plugin(tauri_plugin_global_shortcut::Builder::new().build())
        .setup(|app| {
            // Register global shortcut Cmd+Shift+A
            let shortcut: Shortcut = "CmdOrCtrl+Shift+A".parse().expect("Invalid shortcut");
            app.global_shortcut().on_shortcut(shortcut, |app, _shortcut, event| {
                if let ShortcutState::Pressed = event.state {
                    if let Some(window) = app.get_webview_window("main") {
                        let _ = window.show();
                        let _ = window.set_focus();
                        let _ = app.emit("paste-from-clipboard", ());
                    }
                }
            }).expect("Failed to register global shortcut");

            // Tray icon click shows the window
            let _tray = app.tray_by_id("main").unwrap_or_else(|| {
                tauri::tray::TrayIconBuilder::new()
                    .tooltip("SnapMark")
                    .on_tray_icon_event(|tray, event| {
                        if let tauri::tray::TrayIconEvent::Click { .. } = event {
                            if let Some(window) = tray.app_handle().get_webview_window("main") {
                                let _ = window.show();
                                let _ = window.set_focus();
                            }
                        }
                    })
                    .show_menu_on_left_click(false)
                    .build(app)
                    .expect("Failed to build tray icon")
            });

            Ok(())
        })
        .invoke_handler(tauri::generate_handler![
            read_clipboard_image,
            write_clipboard_image,
            save_image,
        ])
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}
