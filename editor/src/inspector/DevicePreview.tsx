import { useCallback, useEffect, useRef, useState } from "react";
import { invoke } from "@tauri-apps/api/core";
import { useStore } from "../state/store";
import type { Platform } from "../domain/types";

interface Props {
  platform: Platform;
}

interface InspectPayload {
  screenshot: string;
  elements: Array<Record<string, unknown>>;
  labels: string[];
  indexed: Array<{ index: number; role: string; label: string; frame: string }>;
}

export function DevicePreview({ platform }: Props) {
  const elements = useStore((s) => s.elements);
  const setElements = useStore((s) => s.setElements);
  const showToast = useStore((s) => s.showToast);
  const running = useStore((s) => s.running);
  const sessionId = useStore((s) => s.sessionId);
  const setDetectedApp = useStore((s) => s.setDetectedApp);
  const refreshTick = useStore((s) => s.refreshTick);
  const [screenshot, setScreenshot] = useState<string>("");
  const [loading, setLoading] = useState(false);
  const runningRef = useRef(running);
  const inFlightRef = useRef(false);
  useEffect(() => { runningRef.current = running; }, [running]);

  // Full inspect: screenshot + tree + index + detected app. ~500-800ms.
  // Se usa para el refresh manual (botón ↻) y mount inicial.
  const refresh = useCallback(async (silent = false) => {
    if (inFlightRef.current) return;
    inFlightRef.current = true;
    if (!silent) setLoading(true);
    try {
      const result = await invoke<InspectPayload>("inspect", {
        platform: platform === "android" ? "android" : "ios",
      });
      if (result.screenshot) setScreenshot(result.screenshot);
      setElements(result.indexed);
      const root = result.elements[0] as { role?: string; label?: string; id?: string } | undefined;
      if (root?.role === "Application" && root?.id) {
        setDetectedApp({ name: root.label || root.id, bundle: root.id });
      }
    } catch (e) {
      if (!silent) showToast("err", `Inspect fallo: ${(e as Error).message ?? e}`);
    } finally {
      inFlightRef.current = false;
      if (!silent) setLoading(false);
    }
  }, [platform, setElements, setDetectedApp, showToast]);

  // Fast screenshot-only refresh. Si hay sessionId activa, el backend reusa el
  // sidecar vivo y evita cold-start de simctl → ~100-200ms vs 300-500ms.
  const refreshScreenshotOnly = useCallback(async () => {
    if (inFlightRef.current) return;
    inFlightRef.current = true;
    try {
      const img = await invoke<string>("screenshot_only", {
        platform: platform === "android" ? "android" : "ios",
        sessionId: sessionId ?? null,
      });
      if (img) setScreenshot(img);
    } catch { /* silent — ya hay log en stderr del CLI */ }
    finally { inFlightRef.current = false; }
  }, [platform, sessionId]);

  useEffect(() => {
    void refresh();
  }, [refresh]);

  useEffect(() => {
    setDetectedApp(null);
  }, [platform, setDetectedApp]);

  // Refresh reactivo post-acción: 100ms para dejar que la UI asiente sin
  // perder fluidez. Usa screenshot-only (rápido) — el tree se actualiza solo
  // en refresh manual.
  useEffect(() => {
    if (refreshTick === 0) return;
    const id = setTimeout(() => {
      if (!inFlightRef.current) void refreshScreenshotOnly();
    }, 100);
    return () => clearTimeout(id);
  }, [refreshTick, refreshScreenshotOnly]);

  // Polling continuo mientras running=true: 200ms per-frame → ~5fps mirror.
  // Con el sidecar reusado (no cold-start simctl) cada frame tarda 100-200ms,
  // lo suficiente para ver animaciones fluidas sin saturar.
  useEffect(() => {
    if (!running) return;
    const id = setInterval(() => {
      if (!inFlightRef.current) void refreshScreenshotOnly();
    }, 200);
    return () => clearInterval(id);
  }, [running, refreshScreenshotOnly]);

  return (
    <div data-testid="device-preview">
      <div className="section-title" style={{ display: "flex", justifyContent: "space-between" }}>
        <span>Device · {platform}</span>
        <button className="btn btn-icon" onClick={() => void refresh()} title="Refresh">
          ↻
        </button>
      </div>
      <div className="device-preview">
        <div className="screen">
          {screenshot && <img src={screenshot} alt="device" style={{ width: "100%", height: "100%", objectFit: "cover" }} />}
          {!screenshot && (
            <div
              style={{
                color: "var(--text-mute)",
                fontSize: 11,
                textAlign: "center",
                paddingTop: "50%",
              }}
            >
              {loading ? "Capturando..." : "Sin dispositivo"}
            </div>
          )}
        </div>
      </div>
      {elements.length > 0 && (
        <div style={{ marginTop: 12 }}>
          <div className="section-title">{elements.length} elementos</div>
          <div style={{ fontSize: 11, color: "var(--text-dim)", fontFamily: "JetBrains Mono, monospace" }}>
            {elements.slice(0, 8).map((e) => (
              <div key={e.index} style={{ padding: "2px 0" }}>
                ${e.index} {e.role} · "{e.label}"
              </div>
            ))}
            {elements.length > 8 && <div>…y {elements.length - 8} mas</div>}
          </div>
        </div>
      )}
    </div>
  );
}
