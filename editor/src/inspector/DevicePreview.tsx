import { useCallback, useEffect, useRef, useState } from "react";
import { invoke } from "@tauri-apps/api/core";
import { useStore } from "../state/store";
import type { Platform } from "../domain/types";
import { ensureFreshElements } from "../services/elements";

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
  const [elementsOpen, setElementsOpen] = useState(true);
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

  // Mount (#189): SOLO screenshot (simctl, sin foco) + índice via sesión si
  // hay una viva. El inspect completo (tree AX frío — roba el foco y lista
  // el chrome del Simulator) queda para el botón ↻ manual.
  useEffect(() => {
    void refreshScreenshotOnly();
    if (useStore.getState().sessionId) {
      void ensureFreshElements(platform === "android" ? "android" : "ios", 0);
    }
  }, [refreshScreenshotOnly, platform]);

  useEffect(() => {
    setDetectedApp(null);
  }, [platform, setDetectedApp]);

  // Refresh reactivo post-acción: 100ms para dejar que la UI asiente sin
  // perder fluidez. Usa screenshot-only (rápido). El tree/index se refresca
  // aparte con debounce (#189) para que el predictivo de elementos siga a
  // las acciones — antes solo se actualizaba al montar o con ↻ manual y el
  // autocomplete operaba sobre un tree stale.
  useEffect(() => {
    if (refreshTick === 0) return;
    const id = setTimeout(() => {
      if (!inFlightRef.current) void refreshScreenshotOnly();
    }, 100);
    const treeId = setTimeout(() => {
      void ensureFreshElements(platform === "android" ? "android" : "ios");
    }, 700);
    return () => {
      clearTimeout(id);
      clearTimeout(treeId);
    };
  }, [refreshTick, refreshScreenshotOnly, platform]);

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
    <div className="device-panel" data-testid="device-preview">
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
        <div className="element-section">
          <div className="section-title">
            <span>{elements.length} elementos</span>
            <button
              className="btn btn-icon"
              data-testid="toggle-elements"
              title={elementsOpen ? "Colapsar lista" : "Expandir lista"}
              onClick={() => setElementsOpen((o) => !o)}
            >
              {elementsOpen ? "−" : "+"}
            </button>
          </div>
          {elementsOpen && (
            <div className="element-list" data-testid="element-list">
              {elements.map((e) => (
                <div key={e.index} className="element-row" title={`$${e.index} ${e.role} · "${e.label}" ${e.frame}`}>
                  ${e.index} {e.role} · "{e.label}"
                </div>
              ))}
            </div>
          )}
        </div>
      )}
    </div>
  );
}
