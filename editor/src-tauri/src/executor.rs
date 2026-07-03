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
    // Pending requests keyed by a monotonic request id (solo diagnóstico).
    // INVARIANTE (#172/#173): esta queue refleja EXACTAMENTE el orden de las
    // líneas escritas a stdin — el sidecar responde FIFO estricto (un frame
    // por línea), así que cada frame que llega consume el slot del frente.
    // Un timeout NO remueve su entrada: el frame tardío llegará igual y debe
    // consumir su propio slot (removerla desalineaba la cola y entregaba
    // frames al waiter equivocado + "orphan frame" al final).
    pending: Arc<Mutex<VecDeque<(u64, oneshot::Sender<Frame>)>>>,
    next_req_id: Arc<Mutex<u64>>,
    dead: Arc<Mutex<Option<String>>>,
    child: Arc<Mutex<Option<Child>>>,
}

impl Session {
    pub fn platform(&self) -> &str {
        &self.platform
    }

    /// Construye la sesión a partir de un child ya spawneado (stdin/stdout
    /// piped) y arranca el reader task que resuelve los pending en FIFO.
    /// Separado de `ExecutorRegistry::spawn` para poder testear la semántica
    /// de la cola con un sidecar fake (sh) sin el binario real.
    fn from_child(mut child: Child, platform: &str) -> Result<Arc<Session>, String> {
        let stdin = child.stdin.take().ok_or("no stdin")?;
        let stdout = child.stdout.take().ok_or("no stdout")?;

        let id = format!("sess_{}", uuid::Uuid::new_v4());
        let pending: Arc<Mutex<VecDeque<(u64, oneshot::Sender<Frame>)>>> =
            Arc::new(Mutex::new(VecDeque::new()));
        let dead: Arc<Mutex<Option<String>>> = Arc::new(Mutex::new(None));

        let session = Arc::new(Session {
            id,
            platform: platform.to_string(),
            writer: Arc::new(Mutex::new(Some(stdin))),
            pending: pending.clone(),
            next_req_id: Arc::new(Mutex::new(0)),
            dead: dead.clone(),
            child: Arc::new(Mutex::new(Some(child))),
        });

        // Reader task
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
                        // FIFO estricto: este frame corresponde al request del
                        // frente de la cola. Si su waiter expiró (timeout), el
                        // rx está dropeado y send() falla — el frame igual
                        // consumió SU slot, así que los siguientes quedan
                        // alineados con sus waiters.
                        let maybe_tx = {
                            let mut pending = pending.lock().await;
                            pending.pop_front()
                        };
                        match maybe_tx {
                            Some((req_id, tx)) => {
                                if tx.send(frame).is_err() {
                                    eprintln!(
                                        "[executor] late frame for req {} (waiter timed out) — dropped",
                                        req_id
                                    );
                                }
                            }
                            None => eprintln!("[executor] orphan frame: {:?}", frame),
                        }
                    }
                    Ok(None) => {
                        *dead.lock().await = Some("EOF from CLI".to_string());
                        let mut pending = pending.lock().await;
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
                        *dead.lock().await = Some(format!("read error: {}", e));
                        break;
                    }
                }
            }
        });

        Ok(session)
    }

    pub async fn send(&self, line: &str, timeout: Duration) -> Result<Frame, String> {
        if let Some(reason) = self.dead.lock().await.clone() {
            return Err(format!("session dead: {}", reason));
        }

        // Id monotónico — solo para diagnóstico (log de frames tardíos) y
        // para limpiar la entrada si el write a stdin falla.
        let req_id = {
            let mut id = self.next_req_id.lock().await;
            *id += 1;
            *id
        };

        let (tx, rx) = oneshot::channel::<Frame>();

        // CRÍTICO: el push a pending y el write a stdin ocurren bajo el MISMO
        // lock del writer. Dos send() concurrentes (runner + mirror/recorder)
        // podían encolar en orden A,B pero escribir B,A — y el matching FIFO
        // entregaba las respuestas cruzadas (#172).
        {
            let mut w = self.writer.lock().await;
            let writer = w
                .as_mut()
                .ok_or_else(|| "session writer closed".to_string())?;
            {
                let mut pending = self.pending.lock().await;
                pending.push_back((req_id, tx));
            }
            let write_result: Result<(), String> = async {
                writer
                    .write_all(line.as_bytes())
                    .await
                    .map_err(|e| format!("write: {}", e))?;
                writer
                    .write_all(b"\n")
                    .await
                    .map_err(|e| format!("write newline: {}", e))?;
                writer.flush().await.map_err(|e| format!("flush: {}", e))
            }
            .await;
            if let Err(e) = write_result {
                // La línea no llegó completa al CLI → no habrá frame para
                // este slot. Aquí SÍ removemos (no hay respuesta que consumir).
                let mut pending = self.pending.lock().await;
                pending.retain(|(id, _)| *id != req_id);
                return Err(e);
            }
        }

        match tokio::time::timeout(timeout, rx).await {
            Ok(Ok(frame)) => Ok(frame),
            Ok(Err(_)) => Err("sender dropped — session likely crashed".to_string()),
            Err(_) => {
                // NO remover la entrada: el sidecar es FIFO estricto y va a
                // responder a este comando tarde o temprano — ese frame debe
                // consumir este slot para no desalinear los que siguen. El
                // rx se dropea aquí; el reader loguea el frame tardío.
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

        let child = Command::new(&bin)
            .arg("interactive")
            .env("PATH", extended_path())
            .env("ANDROID_HOME", android_home())
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .map_err(|e| format!("spawn failed: {} (bin={})", e, bin.display()))?;

        let session = Session::from_child(child, platform)?;
        let id = session.id.clone();
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

    // Sidecar fake con semántica FIFO real: "slow" responde tras ~600ms,
    // el resto al instante. Sirve para probar la cola sin el binario `auto`.
    fn spawn_fake_sidecar() -> Arc<Session> {
        let script = r#"
            echo '{"ready":true,"platform":"fake"}'
            while IFS= read -r line; do
              case "$line" in
                slow*) sleep 0.6; echo '{"ok":true,"out":"SLOW"}' ;;
                *)     echo '{"ok":true,"out":"FAST"}' ;;
              esac
            done
        "#;
        let child = Command::new("sh")
            .arg("-c")
            .arg(script)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .expect("spawn fake sidecar");
        Session::from_child(child, "fake").expect("session from fake child")
    }

    // Regresión #172/#173: un request que expira su timeout NO debe remover
    // su slot de la cola — el sidecar (FIFO estricto) responde igual, y ese
    // frame tardío tiene que consumir SU slot. Antes (retain por id) el frame
    // tardío se entregaba al siguiente waiter: aquí "fast" habría recibido
    // out=="SLOW" y el frame de "fast" quedaba huérfano.
    #[tokio::test]
    async fn late_frame_after_timeout_does_not_shift_queue() {
        let session = spawn_fake_sidecar();

        let res = session.send("slow", Duration::from_millis(100)).await;
        assert!(res.is_err(), "slow debe expirar el timeout");

        let frame = session
            .send("fast", Duration::from_secs(5))
            .await
            .expect("fast debe responder");
        assert_eq!(
            frame.out.as_deref(),
            Some("FAST"),
            "el waiter de 'fast' recibió el frame tardío de 'slow' — cola desalineada"
        );

        session.kill().await;
    }

    // Sends concurrentes (runner + mirror/recorder) deben mantener el orden
    // pending == orden stdin: cada waiter recibe SU frame aunque se disparen
    // a la vez.
    #[tokio::test]
    async fn concurrent_sends_get_their_own_frames() {
        let session = spawn_fake_sidecar();

        let mut handles = Vec::new();
        for _ in 0..8 {
            let s = session.clone();
            handles.push(tokio::spawn(async move {
                s.send("ping", Duration::from_secs(5)).await
            }));
        }
        for h in handles {
            let frame = h.await.expect("join").expect("frame");
            assert_eq!(frame.out.as_deref(), Some("FAST"));
        }

        session.kill().await;
    }
}
