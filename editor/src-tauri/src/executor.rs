//! NDJSON executor — async, event-driven wrapper around `auto interactive`.
//!
//! Each session owns one CLI child process. Commands are written line-by-line
//! to stdin; responses come back as NDJSON frames. A dedicated reader task
//! parses frames and resolves the corresponding pending oneshot sender.
//!
//! CLI semantics: strictly FIFO. One command in → one frame out (ready banner
//! is the sole exception).

use crate::cli::{android_home, auto_binary, extended_path};
use serde::{Deserialize, Serialize};
use std::collections::{HashMap, VecDeque};
use std::process::Stdio;
use std::sync::Arc;
use std::time::Duration;
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::process::{Child, ChildStdin, Command};
use tokio::sync::{oneshot, Mutex};

pub type SessionId = String;

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct Frame {
    #[serde(default)]
    pub ok: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub ms: Option<u64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub out: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub err: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub ready: Option<bool>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub bye: Option<bool>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub skip: Option<bool>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub platform: Option<String>,
}

pub struct Session {
    pub id: SessionId,
    pub platform: String,
    writer: Arc<Mutex<Option<ChildStdin>>>,
    // Pending requests keyed by a monotonic request id. FIFO order preservado
    // (el sidecar responde en orden). El request id permite que un timeout
    // elimine EL tx correcto (no `pop_front` que puede agarrar otro).
    pending: Arc<Mutex<VecDeque<(u64, oneshot::Sender<Frame>)>>>,
    next_req_id: Arc<Mutex<u64>>,
    dead: Arc<Mutex<Option<String>>>,
    child: Arc<Mutex<Option<Child>>>,
}

impl Session {
    pub fn platform(&self) -> &str {
        &self.platform
    }

    pub async fn send(&self, line: &str, timeout: Duration) -> Result<Frame, String> {
        if let Some(reason) = self.dead.lock().await.clone() {
            return Err(format!("session dead: {}", reason));
        }

        // Allocar un id monotónico para esta request — permite que el timeout
        // elimine exactamente este tx sin afectar otros in-flight.
        let req_id = {
            let mut id = self.next_req_id.lock().await;
            *id += 1;
            *id
        };

        let (tx, rx) = oneshot::channel::<Frame>();
        {
            let mut pending = self.pending.lock().await;
            pending.push_back((req_id, tx));
        }

        {
            let mut w = self.writer.lock().await;
            let writer = w
                .as_mut()
                .ok_or_else(|| "session writer closed".to_string())?;
            writer
                .write_all(line.as_bytes())
                .await
                .map_err(|e| format!("write: {}", e))?;
            writer
                .write_all(b"\n")
                .await
                .map_err(|e| format!("write newline: {}", e))?;
            writer.flush().await.map_err(|e| format!("flush: {}", e))?;
        }

        match tokio::time::timeout(timeout, rx).await {
            Ok(Ok(frame)) => Ok(frame),
            Ok(Err(_)) => Err("sender dropped — session likely crashed".to_string()),
            Err(_) => {
                // Eliminar ESTE req_id de la queue sin tocar otros. Si el
                // frame llega después, el reader lo consumirá (el próximo
                // del pending que ya avanzó) o lo logueará como orphan.
                let mut pending = self.pending.lock().await;
                pending.retain(|(id, _)| *id != req_id);
                Err(format!("timeout after {:?}", timeout))
            }
        }
    }

    pub async fn kill(&self) {
        *self.dead.lock().await = Some("killed".to_string());
        let mut child_lock = self.child.lock().await;
        if let Some(mut c) = child_lock.take() {
            let _ = c.kill().await;
            let _ = c.wait().await;
        }
        self.writer.lock().await.take();
        // Drain pending with failure
        let mut pending = self.pending.lock().await;
        while let Some((_, tx)) = pending.pop_front() {
            let _ = tx.send(Frame {
                ok: false,
                err: Some("session killed".to_string()),
                ..Default::default()
            });
        }
    }

    pub async fn is_dead(&self) -> Option<String> {
        self.dead.lock().await.clone()
    }
}

pub struct ExecutorRegistry {
    sessions: Mutex<HashMap<SessionId, Arc<Session>>>,
}

impl ExecutorRegistry {
    pub fn new() -> Self {
        Self {
            sessions: Mutex::new(HashMap::new()),
        }
    }

    pub async fn spawn(&self, platform: &str) -> Result<SessionId, String> {
        let bin = auto_binary(platform);
        if !bin.exists() {
            return Err(format!(
                "CLI binary not found for platform '{}' (tried {})",
                platform,
                bin.display()
            ));
        }

        let mut child = Command::new(&bin)
            .arg("interactive")
            .env("PATH", extended_path())
            .env("ANDROID_HOME", android_home())
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .map_err(|e| format!("spawn failed: {} (bin={})", e, bin.display()))?;

        let stdin = child.stdin.take().ok_or("no stdin")?;
        let stdout = child.stdout.take().ok_or("no stdout")?;

        let id = format!("sess_{}", uuid::Uuid::new_v4());
        let pending: Arc<Mutex<VecDeque<(u64, oneshot::Sender<Frame>)>>> =
            Arc::new(Mutex::new(VecDeque::new()));
        let next_req_id: Arc<Mutex<u64>> = Arc::new(Mutex::new(0));
        let dead: Arc<Mutex<Option<String>>> = Arc::new(Mutex::new(None));

        let session = Arc::new(Session {
            id: id.clone(),
            platform: platform.to_string(),
            writer: Arc::new(Mutex::new(Some(stdin))),
            pending: pending.clone(),
            next_req_id,
            dead: dead.clone(),
            child: Arc::new(Mutex::new(Some(child))),
        });

        // Reader task
        let pending_r = pending.clone();
        let dead_r = dead.clone();
        tokio::spawn(async move {
            let reader = BufReader::new(stdout);
            let mut lines = reader.lines();
            let mut ready_seen = false;
            loop {
                match lines.next_line().await {
                    Ok(Some(line)) => {
                        let frame: Frame = match serde_json::from_str(&line) {
                            Ok(f) => f,
                            Err(e) => {
                                eprintln!("[executor] parse error: {} ({})", e, line);
                                continue;
                            }
                        };
                        if frame.ready == Some(true) && !ready_seen {
                            ready_seen = true;
                            continue;
                        }
                        // El sidecar responde en orden FIFO — pop del primer
                        // pending. Si un send() expiró su timeout, ya se
                        // removió del queue vía retain() por id.
                        let maybe_tx = {
                            let mut pending = pending_r.lock().await;
                            pending.pop_front().map(|(_, tx)| tx)
                        };
                        if let Some(tx) = maybe_tx {
                            let _ = tx.send(frame);
                        } else {
                            eprintln!("[executor] orphan frame: {:?}", frame);
                        }
                    }
                    Ok(None) => {
                        *dead_r.lock().await = Some("EOF from CLI".to_string());
                        let mut pending = pending_r.lock().await;
                        while let Some((_, tx)) = pending.pop_front() {
                            let _ = tx.send(Frame {
                                ok: false,
                                err: Some("session closed (EOF)".to_string()),
                                ..Default::default()
                            });
                        }
                        break;
                    }
                    Err(e) => {
                        *dead_r.lock().await = Some(format!("read error: {}", e));
                        break;
                    }
                }
            }
        });

        self.sessions.lock().await.insert(id.clone(), session);
        Ok(id)
    }

    pub async fn send(
        &self,
        id: &str,
        line: &str,
        timeout_ms: Option<u64>,
    ) -> Result<Frame, String> {
        let session = {
            let sessions = self.sessions.lock().await;
            sessions
                .get(id)
                .cloned()
                .ok_or_else(|| format!("unknown session {}", id))?
        };
        let timeout = Duration::from_millis(timeout_ms.unwrap_or(30_000));
        session.send(line, timeout).await
    }

    pub async fn kill(&self, id: &str) -> Result<(), String> {
        let session = {
            let mut sessions = self.sessions.lock().await;
            sessions.remove(id)
        };
        if let Some(s) = session {
            s.kill().await;
        }
        Ok(())
    }

    pub async fn kill_all(&self) {
        let sessions: Vec<Arc<Session>> = {
            let mut map = self.sessions.lock().await;
            map.drain().map(|(_, s)| s).collect()
        };
        for s in sessions {
            s.kill().await;
        }
    }

    pub async fn status(&self, id: &str) -> Result<serde_json::Value, String> {
        let session = {
            let sessions = self.sessions.lock().await;
            sessions
                .get(id)
                .cloned()
                .ok_or_else(|| format!("unknown session {}", id))?
        };
        let dead = session.is_dead().await;
        Ok(serde_json::json!({
            "id": session.id,
            "platform": session.platform,
            "dead": dead,
        }))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn frame_deserializes_ready_banner() {
        let s = r#"{"ready":true,"platform":"ios"}"#;
        let f: Frame = serde_json::from_str(s).unwrap();
        assert_eq!(f.ready, Some(true));
        assert_eq!(f.platform.as_deref(), Some("ios"));
    }

    #[test]
    fn frame_deserializes_success() {
        let s = r#"{"ok":true,"ms":340,"out":"PONG"}"#;
        let f: Frame = serde_json::from_str(s).unwrap();
        assert!(f.ok);
        assert_eq!(f.ms, Some(340));
        assert_eq!(f.out.as_deref(), Some("PONG"));
    }

    #[test]
    fn frame_deserializes_error() {
        let s = r#"{"ok":false,"ms":5000,"err":"timeout"}"#;
        let f: Frame = serde_json::from_str(s).unwrap();
        assert!(!f.ok);
        assert_eq!(f.err.as_deref(), Some("timeout"));
    }

    #[tokio::test]
    async fn registry_rejects_unknown_session() {
        let reg = ExecutorRegistry::new();
        let res = reg.send("bogus", "ping", None).await;
        assert!(res.is_err());
    }
}
