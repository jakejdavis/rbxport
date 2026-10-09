//! Local support report attachments. The attachment is captured once for
//! preview before the user explicitly chooses whether to submit it.
use std::fmt::Write as _;
use tauri::{Manager, State, WebviewUrl, WebviewWindowBuilder};
use crate::error::{AppError, AppResult};

#[tauri::command]
#[allow(clippy::needless_pass_by_value)]
pub async fn open_report_window(app: tauri::AppHandle) -> AppResult<()> {
    if let Some(window) = app.get_webview_window("report") {
        let _ = window.unminimize();
        let _ = window.set_focus();
        return Ok(());
    }
    let builder = WebviewWindowBuilder::new(&app, "report", WebviewUrl::App("index.html".into()))
        // Top frame only. On Windows wry runs initialization scripts in every
        // frame whatever it is told, and this one used to set `#report` on
        // Cloudflare's Turnstile frames inside the window, which Turnstile
        // failed with 600010.
        .initialization_script("if (window === window.top && !location.hash) location.hash = '#report';")
        .title("Report bug");
    let builder = match crate::browser_args() {
        Some(args) => builder.additional_browser_args(&args),
        None => builder,
    };
    #[cfg(target_os = "macos")]
    let builder = builder.title_bar_style(tauri::TitleBarStyle::Overlay).hidden_title(true);
    let window = builder.inner_size(660.0, 650.0).min_inner_size(480.0, 440.0).visible(false)
        .build().map_err(|e| AppError::internal(format!("The report window could not open: {e}")))?;
    let _ = window.hide_menu();
    Ok(())
}

#[tauri::command]
pub async fn report_attachment(player: State<'_, std::sync::Arc<crate::player::Player>>) -> AppResult<String> {
    let health = player.opened().map(|engine| engine.audio_health()).unwrap_or_default();
    crate::commands::blocking("report_attachment", move || {
        let mut text = format!("System information\nrbxport {}\nOS: {} {}\nArchitecture: {}\nAudio deadline load: {:.1}%\nAudio callback overruns: {}\n",
            env!("CARGO_PKG_VERSION"), std::env::consts::OS,
            sysinfo::System::os_version().unwrap_or_default(), std::env::consts::ARCH,
            health.load * 100.0, health.xruns);
        let sample = crate::diagnostics::sample_shared();
        let _ = writeln!(text, "Process CPU: {:.1}% of one core\nResident memory: {:.1} MiB", sample.cpu, sample.memory_mb);
        text.push_str("\nApplication log (latest file)\n");
        text.push_str(&rbl_app::logs::read_latest(&crate::logging::log_dir())?);
        Ok(text)
    }).await
}

/// Open a copy of the exact attachment captured by the report form.
#[tauri::command]
pub async fn open_report_attachment(app: tauri::AppHandle, attachment: String) -> AppResult<()> {
    use tauri_plugin_opener::OpenerExt;
    let directory = app.path().app_cache_dir().map_err(|e| AppError::internal(e.to_string()))?;
    crate::commands::blocking("open_report_attachment", move || {
        std::fs::create_dir_all(&directory).map_err(|e| AppError::internal(e.to_string()))?;
        let path = directory.join("report-attachment.txt");
        crate::grid::write_atomically(&path, attachment.as_bytes())
            .map_err(|e| AppError::internal(format!("The attachment could not be written: {e}")))?;
        app.opener().open_path(path.to_string_lossy(), None::<&str>)
            .map_err(|e| AppError::internal(format!("The text editor could not open: {e}")))
    }).await
}
