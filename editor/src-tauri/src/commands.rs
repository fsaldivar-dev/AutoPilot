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
        let plat = plat.clone();
        tokio::spawn(async move { take_screenshot_async(&bin, &plat).await })
    };
    let tree_fut = {
        let bin = bin.clone();
        tokio::spawn(async move {
            let stdout = run_cli_async(&bin, &["tree"]).await?;
            Ok::<_, String>(parse_tree_output(&stdout))
        })
    };
    // En iOS el index es un comando independiente — tercer spawn en paralelo
    // con screenshot+tree. En Android se deriva del tree, así que espera.
    let index_fut = if plat == "android" {
        None
    } else {
        let bin = bin.clone();
        Some(tokio::spawn(async move {
            let stdout = run_cli_async(&bin, &["index"]).await.unwrap_or_default();
            parse_index_output(&stdout)
        }))
    };

    let screenshot = screenshot_fut.await.unwrap_or_default();
    let (elements, labels) = tree_fut
        .await
        .map_err(|e| format!("tree join: {}", e))??;

    let index_elements = match index_fut {
        Some(fut) => fut.await.unwrap_or_default(),
        None => index_from_tree(&elements),
    };

    Ok(serde_json::json!({
        "screenshot": format!("data:image/png;base64,{}", screenshot),
        "elements": elements,
        "labels": labels,
        "indexed": index_elements,
    }))
}

/// Path temporal ÚNICO por captura (#173): un nombre fijo compartido entre
/// plataformas y llamadas concurrentes (mirror poller + recorder + inspect)
/// permitía que un frame tardío de Android escribiera el PNG que luego leía
/// la llamada de iOS — mirror cruzado. Con uuid por llamada nadie pisa a nadie.
fn unique_tmp_png(tag: &str, platform: &str) -> std::path::PathBuf {
    std::env::temp_dir().join(format!(
        "autopilot-{}-{}-{}.png",
        tag,
        platform,
        uuid::Uuid::new_v4()
    ))
}

async fn take_screenshot_async(bin: &std::path::PathBuf, platform: &str) -> String {
    use base64::Engine;
    let tmp = unique_tmp_png("inspect", platform);
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

/// Captura solo un screenshot (sin tree/index) para el mirror reactivo del
/// preview. Estrategia:
///   1. Si hay session_id activa → reusa el sidecar interactive (no cold start)
///      via executor.send "screenshot /tmp/x.png" — ~100-200ms.
///   2. Fallback: spawn `auto screenshot` fresco (~300-500ms por cold start).
///
/// El sidecar reusado es crítico para que el preview sienta fluido.
#[tauri::command]
pub async fn screenshot_only(
    platform: Option<String>,
    session_id: Option<String>,
    registry: State<'_, Arc<ExecutorRegistry>>,
) -> Result<String, String> {
    use base64::Engine;

    let plat = platform.as_deref().unwrap_or("ios").to_string();

    // Path 1 (rápido): sidecar ya corriendo — mandar screenshot por stdin.
    // El path es único por llamada (#173): con el nombre fijo compartido,
    // dos capturas concurrentes (mirror + recorder, o iOS + Android) se
    // borraban/pisaban el archivo entre sí — el mirror de iOS llegó a mostrar
    // la pantalla de Android escrita por un frame tardío.
    if let Some(sid) = session_id.as_deref() {
        let tmp = unique_tmp_png("mirror", &plat);
        let line = format!("screenshot {}", tmp.to_string_lossy());
        match registry.send(sid, &line, Some(5_000)).await {
            Ok(frame) if frame.ok => {
                if let Ok(bytes) = tokio::fs::read(&tmp).await {
                    let _ = tokio::fs::remove_file(&tmp).await;
                    let b64 = base64::engine::general_purpose::STANDARD.encode(&bytes);
                    return Ok(format!("data:image/png;base64,{}", b64));
                }
            }
            _ => {
                // Timeout o error del sidecar. Si responde tarde, el PNG se
                // escribirá igual — limpieza diferida para no acumular en tmp.
                tokio::spawn(async move {
                    tokio::time::sleep(std::time::Duration::from_secs(30)).await;
                    let _ = tokio::fs::remove_file(&tmp).await;
                });
            }
        }
    }

    // Path 2 (cold start): spawn proceso fresco.
    let bin = auto_binary(&plat);
    let b64 = take_screenshot_async(&bin, &plat).await;
    if b64.is_empty() {
        return Err("screenshot failed (empty)".into());
    }
    Ok(format!("data:image/png;base64,{}", b64))
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
pub async fn interactive_stop(
    registry: State<'_, Arc<ExecutorRegistry>>,
) -> Result<(), String> {
    registry.kill_all().await;
    Ok(())
}

// ---- DB commands ----
//
// SQLite es I/O bloqueante (Mutex<Connection>): cada comando corre el acceso
// en spawn_blocking para no ocupar el main thread de la UI de Tauri.

async fn with_db<T, F>(db: &State<'_, Arc<Db>>, f: F) -> Result<T, String>
where
    T: Send + 'static,
    F: FnOnce(&Db) -> Result<T, String> + Send + 'static,
{
    let db = Arc::clone(db.inner());
    tauri::async_runtime::spawn_blocking(move || f(&db))
        .await
        .map_err(|e| format!("db task join: {}", e))?
}

#[tauri::command]
pub async fn db_list_projects(db: State<'_, Arc<Db>>) -> Result<Vec<ProjectRow>, String> {
    with_db(&db, |db| db.list_projects()).await
}

#[tauri::command]
pub async fn db_upsert_project(row: ProjectRow, db: State<'_, Arc<Db>>) -> Result<(), String> {
    with_db(&db, move |db| db.upsert_project(&row)).await
}

#[tauri::command]
pub async fn db_delete_project(id: String, db: State<'_, Arc<Db>>) -> Result<(), String> {
    with_db(&db, move |db| db.delete_project(&id)).await
}

#[tauri::command]
pub async fn db_list_flows(
    project_id: String,
    db: State<'_, Arc<Db>>,
) -> Result<Vec<FlowRow>, String> {
    with_db(&db, move |db| db.list_flows(&project_id)).await
}

#[tauri::command]
pub async fn db_upsert_flow(row: FlowRow, db: State<'_, Arc<Db>>) -> Result<(), String> {
    with_db(&db, move |db| db.upsert_flow(&row)).await
}

#[tauri::command]
pub async fn db_delete_flow(id: String, db: State<'_, Arc<Db>>) -> Result<(), String> {
    with_db(&db, move |db| db.delete_flow(&id)).await
}

#[tauri::command]
pub async fn db_list_components(
    project_id: String,
    db: State<'_, Arc<Db>>,
) -> Result<Vec<ComponentRow>, String> {
    with_db(&db, move |db| db.list_components(&project_id)).await
}

#[tauri::command]
pub async fn db_upsert_component(
    row: ComponentRow,
    db: State<'_, Arc<Db>>,
) -> Result<(), String> {
    with_db(&db, move |db| db.upsert_component(&row)).await
}

#[tauri::command]
pub async fn db_delete_component(id: String, db: State<'_, Arc<Db>>) -> Result<(), String> {
    with_db(&db, move |db| db.delete_component(&id)).await
}

#[tauri::command]
pub async fn db_list_env_vars(
    project_id: String,
    db: State<'_, Arc<Db>>,
) -> Result<Vec<EnvVarRow>, String> {
    with_db(&db, move |db| db.list_env_vars(&project_id)).await
}

#[tauri::command]
pub async fn db_upsert_env_var(row: EnvVarRow, db: State<'_, Arc<Db>>) -> Result<(), String> {
    with_db(&db, move |db| db.upsert_env_var(&row)).await
}

#[tauri::command]
pub async fn db_delete_env_var(
    project_id: String,
    scope: String,
    key: String,
    db: State<'_, Arc<Db>>,
) -> Result<(), String> {
    with_db(&db, move |db| db.delete_env_var(&project_id, &scope, &key)).await
}

#[tauri::command]
pub async fn db_save_run(row: RunRecordRow, db: State<'_, Arc<Db>>) -> Result<(), String> {
    with_db(&db, move |db| db.save_run(&row)).await
}

#[tauri::command]
pub async fn db_list_runs(
    flow_id: String,
    limit: Option<i64>,
    db: State<'_, Arc<Db>>,
) -> Result<Vec<RunRecordRow>, String> {
    with_db(&db, move |db| db.list_runs(&flow_id, limit.unwrap_or(20))).await
}

#[tauri::command]
pub async fn db_delete_run(id: String, db: State<'_, Arc<Db>>) -> Result<(), String> {
    with_db(&db, move |db| db.delete_run(&id)).await
}

/// Guarda el screenshot de un paso. `data_url` es un data-URI
/// (`data:image/png;base64,...`) tal como lo entrega `screenshot_only`; se
/// decodifica a bytes PNG y se guarda como BLOB ligado al run.
#[tauri::command]
pub async fn db_save_screenshot(
    id: String,
    run_id: String,
    captured_at: i64,
    data_url: String,
    db: State<'_, Arc<Db>>,
) -> Result<(), String> {
    use base64::Engine;
    let b64 = data_url
        .split_once(",")
        .map(|(_, rest)| rest)
        .unwrap_or(&data_url);
    let bytes = base64::engine::general_purpose::STANDARD
        .decode(b64)
        .map_err(|e| format!("decode screenshot: {}", e))?;
    with_db(&db, move |db| {
        db.save_screenshot(&id, &run_id, captured_at, &bytes)
    })
    .await
}

/// Devuelve el screenshot de un paso como data-URI listo para `<img src>`, o
/// null si no existe.
#[tauri::command]
pub async fn db_get_screenshot(
    id: String,
    db: State<'_, Arc<Db>>,
) -> Result<Option<String>, String> {
    use base64::Engine;
    let bytes = with_db(&db, move |db| db.get_screenshot(&id)).await?;
    Ok(bytes.map(|b| {
        let b64 = base64::engine::general_purpose::STANDARD.encode(&b);
        format!("data:image/png;base64,{}", b64)
    }))
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
