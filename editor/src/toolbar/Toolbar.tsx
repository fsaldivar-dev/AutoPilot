import { useState } from "react";
import { selectCurrentProject, useStore } from "../state/store";
import type { Platform } from "../domain/types";
import { ShareModal } from "../share/ShareModal";
import { RunFlowButton } from "./RunFlowButton";

interface Props {
  platform: Platform;
  setPlatform: (p: Platform) => void;
}

export function Toolbar({ platform, setPlatform }: Props) {
  const project = useStore(selectCurrentProject);
  const currentFlowId = useStore((s) => s.currentFlowId);
  const sessionId = useStore((s) => s.sessionId);
  const running = useStore((s) => s.running);
  const detectedApp = useStore((s) => s.detectedApp);
  const viewMode = useStore((s) => s.viewMode);
  const setViewMode = useStore((s) => s.setViewMode);
  const [showShare, setShowShare] = useState(false);
  const [copied, setCopied] = useState(false);

  async function copyBundle() {
    if (!detectedApp) return;
    try {
      await navigator.clipboard.writeText(detectedApp.bundle);
      setCopied(true);
      setTimeout(() => setCopied(false), 1500);
    } catch { /* clipboard puede fallar */ }
  }

  return (
    <div className="toolbar" data-testid="toolbar">
      <div className="brand-mark">
        <svg width="14" height="14" viewBox="0 0 24 24" fill="none">
          <path
            d="M6 4 L12 18 L18 4 M8.5 13 H15.5"
            stroke="#A78BFA"
            strokeWidth="2"
            strokeLinecap="round"
            strokeLinejoin="round"
          />
        </svg>
      </div>
      <span style={{ fontWeight: 600, fontSize: 14, letterSpacing: "-0.02em" }}>
        AutoPilot Composer
      </span>
      <span style={{ color: "var(--fg-faint)" }}>/</span>
      <span style={{ color: "var(--fg-dim)", fontSize: 13 }}>{project?.name ?? "—"}</span>
      {currentFlowId && <span style={{ color: "var(--fg-faint)" }}>›</span>}
      <span style={{ color: "var(--fg)", fontSize: 13 }} data-testid="current-flow-label">
        {project?.flows.find((f) => f.id === currentFlowId)?.name ?? ""}
      </span>

      <div style={{ flex: 1 }} />

      <div className="platform-toggle" data-testid="view-toggle">
        <button
          className={viewMode === "blocks" ? "active" : ""}
          onClick={() => setViewMode("blocks")}
          title="Vista por bloques"
        >
          Bloques
        </button>
        <button
          className={viewMode === "code" ? "active" : ""}
          onClick={() => setViewMode("code")}
          title="Vista de código .auto"
        >
          Código
        </button>
      </div>

      <div className="platform-toggle" data-testid="platform-toggle">
        <button
          className={platform === "ios" ? "active" : ""}
          onClick={() => setPlatform("ios")}
        >
          iOS
        </button>
        <button
          className={platform === "android" ? "active" : ""}
          onClick={() => setPlatform("android")}
        >
          Android
        </button>
      </div>

      {detectedApp && (
        <button
          className={`app-chip${copied ? " copied" : ""}`}
          onClick={copyBundle}
          title={copied ? "¡Copiado!" : detectedApp.bundle}
          data-testid="app-chip"
        >
          <span className="app-chip-dot" />
          <span className="app-chip-name">{copied ? "¡Copiado!" : detectedApp.name}</span>
        </button>
      )}

      <div
        data-testid="session-badge"
        style={{ fontSize: 11, color: sessionId ? "var(--mint)" : "var(--text-dim)" }}
      >
        {sessionId ? `● sesion activa` : "○ sin sesion"}
      </div>

      {running && (
        <div data-testid="running-indicator" style={{ color: "var(--violet-2)", fontSize: 11 }}>
          corriendo…
        </div>
      )}

      <RunFlowButton platform={platform} />

      <button className="btn" onClick={() => setShowShare(true)} data-testid="share-btn">
        Compartir
      </button>

      {showShare && project && (
        <ShareModal project={project} onClose={() => setShowShare(false)} />
      )}
    </div>
  );
}
