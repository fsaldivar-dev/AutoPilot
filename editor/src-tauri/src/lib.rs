//! AutoPilot Composer — Tauri entry point.
//!
//! Modular backend:
//!   - `cli`      — CLI binary resolution + async invocation
//!   - `tree`     — AX tree + element index parsers
//!   - `executor` — async NDJSON session manager for `auto interactive`
//!   - `db`       — SQLite persistence layer
//!   - `commands` — thin #[tauri::command] wrappers

pub mod cli;
pub mod commands;
pub mod db;
pub mod executor;
pub mod tree;

use std::sync::Arc;

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    // Resolve workspace DB path: $APPDATA/autopilot-editor/workspace.db on
    // macOS, or $HOME/.autopilot-editor/workspace.db as a fallback.
    let home = std::env::var("HOME").unwrap_or_else(|_| "/tmp".to_string());
    let db_path = std::path::PathBuf::from(home)
        .join("Library/Application Support/autopilot-editor/workspace.db");

    let db = db::Db::open(db_path.clone())
        .or_else(|_| db::Db::open(std::path::PathBuf::from("/tmp/autopilot-editor.db")))
        .expect("failed to open editor workspace db");

    let executor = Arc::new(executor::ExecutorRegistry::new());

    tauri::Builder::default()
        .plugin(tauri_plugin_opener::init())
        .plugin(tauri_plugin_shell::init())
        .manage(executor)
        .manage(db)
        .invoke_handler(tauri::generate_handler![
            // legacy / cli-backed
            commands::run_auto,
            commands::get_ax_tree,
            commands::get_element_index,
            commands::inspect,
            commands::open_screenshots,
            // executor (new)
            commands::executor_spawn,
            commands::executor_send,
            commands::executor_kill,
            commands::executor_status,
            // legacy single-session wrappers
            commands::interactive_start,
            commands::interactive_send,
            commands::interactive_stop,
            // db
            commands::db_list_projects,
            commands::db_upsert_project,
            commands::db_delete_project,
            commands::db_list_flows,
            commands::db_upsert_flow,
            commands::db_delete_flow,
            commands::db_list_components,
            commands::db_upsert_component,
            commands::db_delete_component,
            commands::db_list_env_vars,
            commands::db_upsert_env_var,
            commands::db_delete_env_var,
            commands::db_save_run,
            commands::db_list_runs,
            // utility
            commands::bundle_cli_path,
        ])
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}
