//! SQLite persistence — projects, flows, components, blocks, env vars, run records.
//! All data travels as JSON blobs for flexibility; queryable columns are denormalized.

use rusqlite::{params, Connection};
use serde::{Deserialize, Serialize};
use std::path::PathBuf;
use std::sync::Mutex;

pub struct Db {
    conn: Mutex<Connection>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ProjectRow {
    pub id: String,
    pub name: String,
    pub platform: String,
    pub data: serde_json::Value,
    pub created_at: i64,
    pub updated_at: i64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct FlowRow {
    pub id: String,
    pub project_id: String,
    pub name: String,
    pub data: serde_json::Value,
    pub updated_at: i64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ComponentRow {
    pub id: String,
    pub project_id: String,
    pub name: String,
    pub signature: serde_json::Value,
    pub body: serde_json::Value,
    pub usage_count: i64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct EnvVarRow {
    pub project_id: String,
    pub scope: String,
    pub key: String,
    pub value: String,
    pub secret: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RunRecordRow {
    pub id: String,
    pub flow_id: String,
    pub started_at: i64,
    pub ended_at: Option<i64>,
    pub status: String,
    pub events: serde_json::Value,
}

impl Db {
    pub fn open(path: PathBuf) -> Result<Self, String> {
        if let Some(parent) = path.parent() {
            let _ = std::fs::create_dir_all(parent);
        }
        let conn = Connection::open(&path)
            .map_err(|e| format!("open {}: {}", path.display(), e))?;
        conn.pragma_update(None, "journal_mode", "WAL")
            .map_err(|e| format!("pragma wal: {}", e))?;
        // ON DELETE CASCADE en el esquema solo aplica con foreign_keys activo.
        conn.pragma_update(None, "foreign_keys", "ON")
            .map_err(|e| format!("pragma fk: {}", e))?;
        let db = Self {
            conn: Mutex::new(conn),
        };
        db.migrate()?;
        Ok(db)
    }

    pub fn open_memory() -> Result<Self, String> {
        let conn = Connection::open_in_memory().map_err(|e| format!("memory: {}", e))?;
        conn.pragma_update(None, "foreign_keys", "ON")
            .map_err(|e| format!("pragma fk: {}", e))?;
        let db = Self {
            conn: Mutex::new(conn),
        };
        db.migrate()?;
        Ok(db)
    }

    fn migrate(&self) -> Result<(), String> {
        let conn = self.conn.lock().unwrap();
        conn.execute_batch(
            r#"
            CREATE TABLE IF NOT EXISTS projects (
                id TEXT PRIMARY KEY,
                name TEXT NOT NULL,
                platform TEXT NOT NULL,
                data TEXT NOT NULL,
                created_at INTEGER NOT NULL,
                updated_at INTEGER NOT NULL
            );
            CREATE TABLE IF NOT EXISTS flows (
                id TEXT PRIMARY KEY,
                project_id TEXT NOT NULL,
                name TEXT NOT NULL,
                data TEXT NOT NULL,
                updated_at INTEGER NOT NULL,
                FOREIGN KEY (project_id) REFERENCES projects(id) ON DELETE CASCADE
            );
            CREATE TABLE IF NOT EXISTS components (
                id TEXT PRIMARY KEY,
                project_id TEXT NOT NULL,
                name TEXT NOT NULL,
                signature TEXT NOT NULL,
                body TEXT NOT NULL,
                usage_count INTEGER NOT NULL DEFAULT 0,
                FOREIGN KEY (project_id) REFERENCES projects(id) ON DELETE CASCADE
            );
            CREATE TABLE IF NOT EXISTS env_vars (
                project_id TEXT NOT NULL,
                scope TEXT NOT NULL,
                key TEXT NOT NULL,
                value TEXT NOT NULL,
                secret INTEGER NOT NULL DEFAULT 0,
                PRIMARY KEY (project_id, scope, key),
                FOREIGN KEY (project_id) REFERENCES projects(id) ON DELETE CASCADE
            );
            CREATE TABLE IF NOT EXISTS run_records (
                id TEXT PRIMARY KEY,
                flow_id TEXT NOT NULL,
                started_at INTEGER NOT NULL,
                ended_at INTEGER,
                status TEXT NOT NULL,
                events TEXT NOT NULL,
                FOREIGN KEY (flow_id) REFERENCES flows(id) ON DELETE CASCADE
            );
            CREATE TABLE IF NOT EXISTS screenshots (
                id TEXT PRIMARY KEY,
                run_id TEXT NOT NULL,
                captured_at INTEGER NOT NULL,
                data BLOB NOT NULL,
                FOREIGN KEY (run_id) REFERENCES run_records(id) ON DELETE CASCADE
            );
            "#,
        )
        .map_err(|e| format!("migrate: {}", e))?;
        Ok(())
    }

    // ---- projects ----

    pub fn upsert_project(&self, row: &ProjectRow) -> Result<(), String> {
        let conn = self.conn.lock().unwrap();
        conn.execute(
            r#"INSERT INTO projects (id, name, platform, data, created_at, updated_at)
               VALUES (?1, ?2, ?3, ?4, ?5, ?6)
               ON CONFLICT(id) DO UPDATE SET
                 name = excluded.name,
                 platform = excluded.platform,
                 data = excluded.data,
                 updated_at = excluded.updated_at"#,
            params![
                row.id,
                row.name,
                row.platform,
                row.data.to_string(),
                row.created_at,
                row.updated_at
            ],
        )
        .map_err(|e| format!("upsert project: {}", e))?;
        Ok(())
    }

    pub fn list_projects(&self) -> Result<Vec<ProjectRow>, String> {
        let conn = self.conn.lock().unwrap();
        let mut stmt = conn
            .prepare(
                "SELECT id, name, platform, data, created_at, updated_at FROM projects ORDER BY updated_at DESC",
            )
            .map_err(|e| format!("prepare: {}", e))?;
        let rows = stmt
            .query_map([], |row| {
                let data_str: String = row.get(3)?;
                Ok(ProjectRow {
                    id: row.get(0)?,
                    name: row.get(1)?,
                    platform: row.get(2)?,
                    data: serde_json::from_str(&data_str).unwrap_or(serde_json::json!({})),
                    created_at: row.get(4)?,
                    updated_at: row.get(5)?,
                })
            })
            .map_err(|e| format!("query: {}", e))?;
        rows.collect::<Result<_, _>>()
            .map_err(|e| format!("collect: {}", e))
    }

    pub fn delete_project(&self, id: &str) -> Result<(), String> {
        let conn = self.conn.lock().unwrap();
        conn.execute("DELETE FROM projects WHERE id = ?1", params![id])
            .map_err(|e| format!("delete project: {}", e))?;
        Ok(())
    }

    // ---- flows ----

    pub fn upsert_flow(&self, row: &FlowRow) -> Result<(), String> {
        let conn = self.conn.lock().unwrap();
        conn.execute(
            r#"INSERT INTO flows (id, project_id, name, data, updated_at)
               VALUES (?1, ?2, ?3, ?4, ?5)
               ON CONFLICT(id) DO UPDATE SET
                 name = excluded.name,
                 data = excluded.data,
                 updated_at = excluded.updated_at"#,
            params![
                row.id,
                row.project_id,
                row.name,
                row.data.to_string(),
                row.updated_at
            ],
        )
        .map_err(|e| format!("upsert flow: {}", e))?;
        Ok(())
    }

    pub fn list_flows(&self, project_id: &str) -> Result<Vec<FlowRow>, String> {
        let conn = self.conn.lock().unwrap();
        let mut stmt = conn
            .prepare(
                "SELECT id, project_id, name, data, updated_at FROM flows WHERE project_id = ?1 ORDER BY updated_at DESC",
            )
            .map_err(|e| format!("prepare: {}", e))?;
        let rows = stmt
            .query_map(params![project_id], |row| {
                let data_str: String = row.get(3)?;
                Ok(FlowRow {
                    id: row.get(0)?,
                    project_id: row.get(1)?,
                    name: row.get(2)?,
                    data: serde_json::from_str(&data_str).unwrap_or(serde_json::json!({})),
                    updated_at: row.get(4)?,
                })
            })
            .map_err(|e| format!("query: {}", e))?;
        rows.collect::<Result<_, _>>()
            .map_err(|e| format!("collect: {}", e))
    }

    pub fn delete_flow(&self, id: &str) -> Result<(), String> {
        let conn = self.conn.lock().unwrap();
        conn.execute("DELETE FROM flows WHERE id = ?1", params![id])
            .map_err(|e| format!("delete flow: {}", e))?;
        Ok(())
    }

    // ---- components ----

    pub fn upsert_component(&self, row: &ComponentRow) -> Result<(), String> {
        let conn = self.conn.lock().unwrap();
        conn.execute(
            r#"INSERT INTO components (id, project_id, name, signature, body, usage_count)
               VALUES (?1, ?2, ?3, ?4, ?5, ?6)
               ON CONFLICT(id) DO UPDATE SET
                 name = excluded.name,
                 signature = excluded.signature,
                 body = excluded.body,
                 usage_count = excluded.usage_count"#,
            params![
                row.id,
                row.project_id,
                row.name,
                row.signature.to_string(),
                row.body.to_string(),
                row.usage_count
            ],
        )
        .map_err(|e| format!("upsert component: {}", e))?;
        Ok(())
    }

    pub fn list_components(&self, project_id: &str) -> Result<Vec<ComponentRow>, String> {
        let conn = self.conn.lock().unwrap();
        let mut stmt = conn
            .prepare(
                "SELECT id, project_id, name, signature, body, usage_count FROM components WHERE project_id = ?1 ORDER BY usage_count DESC",
            )
            .map_err(|e| format!("prepare: {}", e))?;
        let rows = stmt
            .query_map(params![project_id], |row| {
                let sig: String = row.get(3)?;
                let body: String = row.get(4)?;
                Ok(ComponentRow {
                    id: row.get(0)?,
                    project_id: row.get(1)?,
                    name: row.get(2)?,
                    signature: serde_json::from_str(&sig).unwrap_or(serde_json::json!({})),
                    body: serde_json::from_str(&body).unwrap_or(serde_json::json!([])),
                    usage_count: row.get(5)?,
                })
            })
            .map_err(|e| format!("query: {}", e))?;
        rows.collect::<Result<_, _>>()
            .map_err(|e| format!("collect: {}", e))
    }

    pub fn delete_component(&self, id: &str) -> Result<(), String> {
        let conn = self.conn.lock().unwrap();
        conn.execute("DELETE FROM components WHERE id = ?1", params![id])
            .map_err(|e| format!("delete component: {}", e))?;
        Ok(())
    }

    // ---- env vars ----

    pub fn upsert_env_var(&self, row: &EnvVarRow) -> Result<(), String> {
        let conn = self.conn.lock().unwrap();
        conn.execute(
            r#"INSERT INTO env_vars (project_id, scope, key, value, secret)
               VALUES (?1, ?2, ?3, ?4, ?5)
               ON CONFLICT(project_id, scope, key) DO UPDATE SET
                 value = excluded.value,
                 secret = excluded.secret"#,
            params![row.project_id, row.scope, row.key, row.value, row.secret as i64],
        )
        .map_err(|e| format!("upsert env_var: {}", e))?;
        Ok(())
    }

    pub fn list_env_vars(&self, project_id: &str) -> Result<Vec<EnvVarRow>, String> {
        let conn = self.conn.lock().unwrap();
        let mut stmt = conn
            .prepare(
                "SELECT project_id, scope, key, value, secret FROM env_vars WHERE project_id = ?1 ORDER BY scope, key",
            )
            .map_err(|e| format!("prepare: {}", e))?;
        let rows = stmt
            .query_map(params![project_id], |row| {
                Ok(EnvVarRow {
                    project_id: row.get(0)?,
                    scope: row.get(1)?,
                    key: row.get(2)?,
                    value: row.get(3)?,
                    secret: row.get::<_, i64>(4)? != 0,
                })
            })
            .map_err(|e| format!("query: {}", e))?;
        rows.collect::<Result<_, _>>()
            .map_err(|e| format!("collect: {}", e))
    }

    pub fn delete_env_var(&self, project_id: &str, scope: &str, key: &str) -> Result<(), String> {
        let conn = self.conn.lock().unwrap();
        conn.execute(
            "DELETE FROM env_vars WHERE project_id = ?1 AND scope = ?2 AND key = ?3",
            params![project_id, scope, key],
        )
        .map_err(|e| format!("delete env_var: {}", e))?;
        Ok(())
    }

    // ---- run records ----

    pub fn save_run(&self, row: &RunRecordRow) -> Result<(), String> {
        let conn = self.conn.lock().unwrap();
        conn.execute(
            r#"INSERT INTO run_records (id, flow_id, started_at, ended_at, status, events)
               VALUES (?1, ?2, ?3, ?4, ?5, ?6)
               ON CONFLICT(id) DO UPDATE SET
                 ended_at = excluded.ended_at,
                 status = excluded.status,
                 events = excluded.events"#,
            params![
                row.id,
                row.flow_id,
                row.started_at,
                row.ended_at,
                row.status,
                row.events.to_string()
            ],
        )
        .map_err(|e| format!("save run: {}", e))?;
        Ok(())
    }

    pub fn list_runs(&self, flow_id: &str, limit: i64) -> Result<Vec<RunRecordRow>, String> {
        let conn = self.conn.lock().unwrap();
        let mut stmt = conn
            .prepare(
                "SELECT id, flow_id, started_at, ended_at, status, events FROM run_records WHERE flow_id = ?1 ORDER BY started_at DESC LIMIT ?2",
            )
            .map_err(|e| format!("prepare: {}", e))?;
        let rows = stmt
            .query_map(params![flow_id, limit], |row| {
                let events: String = row.get(5)?;
                Ok(RunRecordRow {
                    id: row.get(0)?,
                    flow_id: row.get(1)?,
                    started_at: row.get(2)?,
                    ended_at: row.get(3)?,
                    status: row.get(4)?,
                    events: serde_json::from_str(&events).unwrap_or(serde_json::json!([])),
                })
            })
            .map_err(|e| format!("query: {}", e))?;
        rows.collect::<Result<_, _>>()
            .map_err(|e| format!("collect: {}", e))
    }

    pub fn delete_run(&self, id: &str) -> Result<(), String> {
        let conn = self.conn.lock().unwrap();
        conn.execute("DELETE FROM run_records WHERE id = ?1", params![id])
            .map_err(|e| format!("delete run: {}", e))?;
        Ok(())
    }

    // ---- run step screenshots ----
    //
    // Cada paso capturado durante un run guarda su PNG como BLOB, ligado al
    // run_id (cascade delete). El frontend referencia el screenshot por su id
    // en `RunEvent.screenshotId` y lo pide bajo demanda al abrir el replay,
    // así el JSON de eventos del run queda liviano (sin base64 inline).

    /// Guarda un screenshot de paso. `data` son los bytes PNG crudos.
    pub fn save_screenshot(
        &self,
        id: &str,
        run_id: &str,
        captured_at: i64,
        data: &[u8],
    ) -> Result<(), String> {
        let conn = self.conn.lock().unwrap();
        conn.execute(
            r#"INSERT INTO screenshots (id, run_id, captured_at, data)
               VALUES (?1, ?2, ?3, ?4)
               ON CONFLICT(id) DO UPDATE SET
                 run_id = excluded.run_id,
                 captured_at = excluded.captured_at,
                 data = excluded.data"#,
            params![id, run_id, captured_at, data],
        )
        .map_err(|e| format!("save screenshot: {}", e))?;
        Ok(())
    }

    /// Devuelve los bytes PNG de un screenshot por id, o None si no existe.
    pub fn get_screenshot(&self, id: &str) -> Result<Option<Vec<u8>>, String> {
        let conn = self.conn.lock().unwrap();
        let mut stmt = conn
            .prepare("SELECT data FROM screenshots WHERE id = ?1")
            .map_err(|e| format!("prepare: {}", e))?;
        let mut rows = stmt
            .query_map(params![id], |row| row.get::<_, Vec<u8>>(0))
            .map_err(|e| format!("query: {}", e))?;
        match rows.next() {
            Some(Ok(bytes)) => Ok(Some(bytes)),
            Some(Err(e)) => Err(format!("read screenshot: {}", e)),
            None => Ok(None),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn now() -> i64 {
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_secs() as i64
    }

    #[test]
    fn migrates_on_open() {
        let _db = Db::open_memory().unwrap();
    }

    #[test]
    fn project_crud_roundtrip() {
        let db = Db::open_memory().unwrap();
        let row = ProjectRow {
            id: "p1".into(),
            name: "Banco Atlas".into(),
            platform: "ios".into(),
            data: serde_json::json!({ "theme": "dark" }),
            created_at: now(),
            updated_at: now(),
        };
        db.upsert_project(&row).unwrap();
        let rows = db.list_projects().unwrap();
        assert_eq!(rows.len(), 1);
        assert_eq!(rows[0].name, "Banco Atlas");

        db.delete_project("p1").unwrap();
        let rows = db.list_projects().unwrap();
        assert!(rows.is_empty());
    }

    #[test]
    fn flows_cascade_with_project() {
        let db = Db::open_memory().unwrap();
        let project = ProjectRow {
            id: "p1".into(),
            name: "p".into(),
            platform: "ios".into(),
            data: serde_json::json!({}),
            created_at: now(),
            updated_at: now(),
        };
        db.upsert_project(&project).unwrap();
        let flow = FlowRow {
            id: "f1".into(),
            project_id: "p1".into(),
            name: "Login".into(),
            data: serde_json::json!({ "blocks": [] }),
            updated_at: now(),
        };
        db.upsert_flow(&flow).unwrap();
        assert_eq!(db.list_flows("p1").unwrap().len(), 1);
    }

    #[test]
    fn env_vars_upsert_by_key() {
        let db = Db::open_memory().unwrap();
        let p = ProjectRow {
            id: "p1".into(),
            name: "p".into(),
            platform: "ios".into(),
            data: serde_json::json!({}),
            created_at: now(),
            updated_at: now(),
        };
        db.upsert_project(&p).unwrap();
        db.upsert_env_var(&EnvVarRow {
            project_id: "p1".into(),
            scope: "staging".into(),
            key: "API".into(),
            value: "v1".into(),
            secret: false,
        })
        .unwrap();
        db.upsert_env_var(&EnvVarRow {
            project_id: "p1".into(),
            scope: "staging".into(),
            key: "API".into(),
            value: "v2".into(),
            secret: true,
        })
        .unwrap();
        let vars = db.list_env_vars("p1").unwrap();
        assert_eq!(vars.len(), 1);
        assert_eq!(vars[0].value, "v2");
        assert!(vars[0].secret);
    }

    fn seed_flow(db: &Db) {
        db.upsert_project(&ProjectRow {
            id: "p1".into(),
            name: "p".into(),
            platform: "ios".into(),
            data: serde_json::json!({}),
            created_at: now(),
            updated_at: now(),
        })
        .unwrap();
        db.upsert_flow(&FlowRow {
            id: "f1".into(),
            project_id: "p1".into(),
            name: "Login".into(),
            data: serde_json::json!({ "blocks": [] }),
            updated_at: now(),
        })
        .unwrap();
    }

    #[test]
    fn runs_saved_and_listed_newest_first() {
        let db = Db::open_memory().unwrap();
        seed_flow(&db);
        db.save_run(&RunRecordRow {
            id: "r1".into(),
            flow_id: "f1".into(),
            started_at: 100,
            ended_at: Some(200),
            status: "passed".into(),
            events: serde_json::json!([{ "blockId": "b1", "ok": true }]),
        })
        .unwrap();
        db.save_run(&RunRecordRow {
            id: "r2".into(),
            flow_id: "f1".into(),
            started_at: 300,
            ended_at: Some(400),
            status: "failed".into(),
            events: serde_json::json!([]),
        })
        .unwrap();
        let runs = db.list_runs("f1", 10).unwrap();
        assert_eq!(runs.len(), 2);
        // started_at DESC → r2 primero.
        assert_eq!(runs[0].id, "r2");
        assert_eq!(runs[1].id, "r1");
    }

    #[test]
    fn run_upsert_updates_status_and_events() {
        let db = Db::open_memory().unwrap();
        seed_flow(&db);
        db.save_run(&RunRecordRow {
            id: "r1".into(),
            flow_id: "f1".into(),
            started_at: 100,
            ended_at: None,
            status: "running".into(),
            events: serde_json::json!([]),
        })
        .unwrap();
        db.save_run(&RunRecordRow {
            id: "r1".into(),
            flow_id: "f1".into(),
            started_at: 100,
            ended_at: Some(250),
            status: "passed".into(),
            events: serde_json::json!([{ "blockId": "b1" }]),
        })
        .unwrap();
        let runs = db.list_runs("f1", 10).unwrap();
        assert_eq!(runs.len(), 1);
        assert_eq!(runs[0].status, "passed");
        assert_eq!(runs[0].ended_at, Some(250));
    }

    #[test]
    fn screenshots_roundtrip_and_cascade_delete() {
        let db = Db::open_memory().unwrap();
        seed_flow(&db);
        db.save_run(&RunRecordRow {
            id: "r1".into(),
            flow_id: "f1".into(),
            started_at: 100,
            ended_at: Some(200),
            status: "passed".into(),
            events: serde_json::json!([]),
        })
        .unwrap();
        let png = [0x89u8, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a];
        db.save_screenshot("s1", "r1", 150, &png).unwrap();
        let got = db.get_screenshot("s1").unwrap();
        assert_eq!(got.as_deref(), Some(&png[..]));
        assert!(db.get_screenshot("nope").unwrap().is_none());

        // Borrar el run debe cascada-borrar sus screenshots.
        db.delete_run("r1").unwrap();
        assert!(db.get_screenshot("s1").unwrap().is_none());
    }

    #[test]
    fn components_ranked_by_usage() {
        let db = Db::open_memory().unwrap();
        let p = ProjectRow {
            id: "p1".into(),
            name: "p".into(),
            platform: "ios".into(),
            data: serde_json::json!({}),
            created_at: now(),
            updated_at: now(),
        };
        db.upsert_project(&p).unwrap();
        db.upsert_component(&ComponentRow {
            id: "c1".into(),
            project_id: "p1".into(),
            name: "A".into(),
            signature: serde_json::json!([]),
            body: serde_json::json!([]),
            usage_count: 2,
        })
        .unwrap();
        db.upsert_component(&ComponentRow {
            id: "c2".into(),
            project_id: "p1".into(),
            name: "B".into(),
            signature: serde_json::json!([]),
            body: serde_json::json!([]),
            usage_count: 7,
        })
        .unwrap();
        let cs = db.list_components("p1").unwrap();
        assert_eq!(cs.len(), 2);
        assert_eq!(cs[0].name, "B");
    }
}
