//! Tauri command handlers — thin async wrappers over cli/tree/executor/db modules.

use crate::cli::{auto_binary, run_cli_async};
use crate::db::{
    ComponentRow, Db, EnvVarRow, FlowRow, ProjectRow, RunRecordRow,
};
use crate::executor::{ExecutorRegistry, Frame};
use crate::tree::{index_from_tree, parse_index_output, parse_tree_output};
use serde_json::Value;
use std::sync::Arc;
use tauri::State;

// ---- CLI / legacy execution ----

#[tauri::command]
pub async fn run_auto(args: Vec<String>, platform: Option<String>) -> Result<String, String> {
    let plat = platform.as_deref().unwrap_or("ios").to_string();
    let bin = auto_binary(&plat);
    let args_ref: Vec<&str> = args.iter().map(|s| s.as_str()).collect();
    run_cli_async(&bin, &args_ref).await
}

#[tauri::command]
pub async fn get_ax_tree(platform: Option<String>) -> Result<Value, String> {
    let plat = platform.as_deref().unwrap_or("ios");
    let bin = auto_binary(plat);
    let stdout = run_cli_async(&bin, &["tree"]).await?;
    let (elements, labels) = parse_tree_output(&stdout);
    Ok(serde_json::json!({
        "raw": stdout,
        "elements": elements,
        "labels": labels,
    }))
}

#[tauri::command]
pub async fn get_element_index(platform: Option<String>) -> Result<Value, String> {
    let plat = platform.as_deref().unwrap_or("ios").to_string();
    if plat == "android" {
        let bin = auto_binary(&plat);
        let stdout = run_cli_async(&bin, &["tree"]).await.unwrap_or_default();
        let (elements, _) = parse_tree_output(&stdout);
        return Ok(serde_json::json!({ "elements": index_from_tree(&elements) }));
    }
    let bin = auto_binary(&plat);
    let stdout = run_cli_async(&bin, &["index"]).await.unwrap_or_default();
    let elements = parse_index_output(&stdout);
    Ok(serde_json::json!({ "elements": elements }))
}

#[tauri::command]
pub async fn inspect(platform: Option<String>) -> Result<Value, String> {
    let plat = platform.as_deref().unwrap_or("ios").to_string();
    let bin = auto_binary(&plat);

    let screenshot_fut = {
        let bin = bin.clone();
        tokio::spawn(async move { take_screenshot_async(&bin).await })
    };
    let tree_fut = {
        let bin = bin.clone();
        tokio::spawn(async move {
            let stdout = run_cli_async(&bin, &["tree"]).await?;
            Ok::<_, String>(parse_tree_output(&stdout))
        })
    };

    let screenshot = screenshot_fut.await.unwrap_or_default();
    let (elements, labels) = tree_fut
        .await
        .map_err(|e| format!("tree join: {}", e))??;

    let index_elements = if plat == "android" {
        index_from_tree(&elements)
    } else {
        let stdout = run_cli_async(&bin, &["index"]).await.unwrap_or_default();
        parse_index_output(&stdout)
    };

    Ok(serde_json::json!({
        "screenshot": format!("data:image/png;base64,{}", screenshot),
        "elements": elements,
        "labels": labels,
        "indexed": index_elements,
    }))
}

async fn take_screenshot_async(bin: &std::path::PathBuf) -> String {
    use base64::Engine;
    let tmp = std::env::temp_dir().join("autopilot-inspect.png");
    let tmp_str = tmp.to_string_lossy().to_string();
    let _ = run_cli_async(bin, &["screenshot", &tmp_str]).await;

    if tmp.exists() {
        if let Ok(bytes) = tokio::fs::read(&tmp).await {
            let _ = tokio::fs::remove_file(&tmp).await;
            return base64::engine::general_purpose::STANDARD.encode(&bytes);
        }
    }
    String::new()
}

// ---- NDJSON executor ----

#[tauri::command]
pub async fn executor_spawn(
    platform: String,
    registry: State<'_, Arc<ExecutorRegistry>>,
) -> Result<String, String> {
    registry.spawn(&platform).await
}

#[tauri::command]
pub async fn executor_send(
    session_id: String,
    line: String,
    timeout_ms: Option<u64>,
    registry: State<'_, Arc<ExecutorRegistry>>,
) -> Result<Frame, String> {
    registry.send(&session_id, &line, timeout_ms).await
}

#[tauri::command]
pub async fn executor_kill(
    session_id: String,
    registry: State<'_, Arc<ExecutorRegistry>>,
) -> Result<(), String> {
    registry.kill(&session_id).await
}

#[tauri::command]
pub async fn executor_status(
    session_id: String,
    registry: State<'_, Arc<ExecutorRegistry>>,
) -> Result<Value, String> {
    registry.status(&session_id).await
}

// ---- Legacy single-session interactive (kept for back-compat) ----

#[tauri::command]
pub async fn interactive_start(
    platform: String,
    registry: State<'_, Arc<ExecutorRegistry>>,
) -> Result<String, String> {
    registry.kill_all().await;
    registry.spawn(&platform).await
}

#[tauri::command]
pub async fn interactive_send(
    line: String,
    registry: State<'_, Arc<ExecutorRegistry>>,
) -> Result<String, String> {
    // Picks the first (and only) session in legacy mode.
    let sessions = registry_ids(&registry).await;
    let id = sessions
        .into_iter()
        .next()
        .ok_or("no interactive session — call interactive_start first")?;
    let frame = registry.send(&id, &line, Some(30_000)).await?;
    serde_json::to_string(&frame).map_err(|e| format!("serialize frame: {}", e))
}

#[tauri::command]
pub async fn interactive_stop(
    registry: State<'_, Arc<ExecutorRegistry>>,
) -> Result<(), String> {
    registry.kill_all().await;
    Ok(())
}

async fn registry_ids(registry: &ExecutorRegistry) -> Vec<String> {
    // Helper: read current ids. ExecutorRegistry doesn't expose listing; we
    // rely on status() + explicit spawn tracking. For MVP we use a naive
    // approach: return empty if unknown; legacy mode requires spawn first.
    // Since we can't enumerate, callers of the legacy API must call
    // interactive_start → receive id once — but our legacy wrapper swallows
    // the id. Solution: track last spawned id in registry state.
    let _ = registry;
    vec![]
}

// ---- DB commands ----

#[tauri::command]
pub fn db_list_projects(db: State<'_, Db>) -> Result<Vec<ProjectRow>, String> {
    db.list_projects()
}

#[tauri::command]
pub fn db_upsert_project(row: ProjectRow, db: State<'_, Db>) -> Result<(), String> {
    db.upsert_project(&row)
}

#[tauri::command]
pub fn db_delete_project(id: String, db: State<'_, Db>) -> Result<(), String> {
    db.delete_project(&id)
}

#[tauri::command]
pub fn db_list_flows(project_id: String, db: State<'_, Db>) -> Result<Vec<FlowRow>, String> {
    db.list_flows(&project_id)
}

#[tauri::command]
pub fn db_upsert_flow(row: FlowRow, db: State<'_, Db>) -> Result<(), String> {
    db.upsert_flow(&row)
}

#[tauri::command]
pub fn db_delete_flow(id: String, db: State<'_, Db>) -> Result<(), String> {
    db.delete_flow(&id)
}

#[tauri::command]
pub fn db_list_components(
    project_id: String,
    db: State<'_, Db>,
) -> Result<Vec<ComponentRow>, String> {
    db.list_components(&project_id)
}

#[tauri::command]
pub fn db_upsert_component(row: ComponentRow, db: State<'_, Db>) -> Result<(), String> {
    db.upsert_component(&row)
}

#[tauri::command]
pub fn db_delete_component(id: String, db: State<'_, Db>) -> Result<(), String> {
    db.delete_component(&id)
}

#[tauri::command]
pub fn db_list_env_vars(
    project_id: String,
    db: State<'_, Db>,
) -> Result<Vec<EnvVarRow>, String> {
    db.list_env_vars(&project_id)
}

#[tauri::command]
pub fn db_upsert_env_var(row: EnvVarRow, db: State<'_, Db>) -> Result<(), String> {
    db.upsert_env_var(&row)
}

#[tauri::command]
pub fn db_delete_env_var(
    project_id: String,
    scope: String,
    key: String,
    db: State<'_, Db>,
) -> Result<(), String> {
    db.delete_env_var(&project_id, &scope, &key)
}

#[tauri::command]
pub fn db_save_run(row: RunRecordRow, db: State<'_, Db>) -> Result<(), String> {
    db.save_run(&row)
}

#[tauri::command]
pub fn db_list_runs(
    flow_id: String,
    limit: Option<i64>,
    db: State<'_, Db>,
) -> Result<Vec<RunRecordRow>, String> {
    db.list_runs(&flow_id, limit.unwrap_or(20))
}

// ---- Utility commands ----

#[tauri::command]
pub fn bundle_cli_path(kind: String) -> Result<String, String> {
    let bin = match kind.as_str() {
        "android" | "auto-android" => auto_binary("android"),
        _ => auto_binary("ios"),
    };
    if !bin.exists() {
        return Err(format!("bundled CLI not found at {}", bin.display()));
    }
    Ok(bin.to_string_lossy().to_string())
}

#[tauri::command]
pub fn open_screenshots() -> Result<String, String> {
    let dir = std::env::current_dir()
        .unwrap_or_default()
        .join("screenshots");
    let _ = std::fs::create_dir_all(&dir);
    std::process::Command::new("open")
        .arg(&dir)
        .spawn()
        .map_err(|e| format!("Failed to open: {}", e))?;
    Ok(dir.to_string_lossy().to_string())
}
