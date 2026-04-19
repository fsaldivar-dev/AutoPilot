import { useState } from "react";
import { selectCurrentProject, useStore } from "../state/store";
import type { Platform } from "../domain/types";
import { ShareModal } from "../share/ShareModal";

interface Props {
  platform: Platform;
  setPlatform: (p: Platform) => void;
}

export function Toolbar({ platform, setPlatform }: Props) {
  const project = useStore(selectCurrentProject);
  const currentFlowId = useStore((s) => s.currentFlowId);
  const sessionId = useStore((s) => s.sessionId);
  const running = useStore((s) => s.running);
  const [showShare, setShowShare] = useState(false);

  return (
    <div className="toolbar" data-testid="toolbar">
      <span style={{ fontWeight: 700, color: "var(--accent)", letterSpacing: -0.5 }}>
        AutoPilot
      </span>
      <span style={{ color: "var(--text-mute)" }}>/</span>
      <span style={{ color: "var(--text-dim)" }}>{project?.name ?? "—"}</span>
      {currentFlowId && <span style={{ color: "var(--text-mute)" }}>/</span>}
      <span style={{ color: "var(--text)" }} data-testid="current-flow-label">
        {project?.flows.find((f) => f.id === currentFlowId)?.name ?? ""}
      </span>

      <div style={{ flex: 1 }} />

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

      <div
        data-testid="session-badge"
        style={{ fontSize: 11, color: sessionId ? "var(--mint)" : "var(--text-dim)" }}
      >
        {sessionId ? `● sesion activa` : "○ sin sesion"}
      </div>

      {running && (
        <div data-testid="running-indicator" style={{ color: "var(--accent)", fontSize: 11 }}>
          corriendo…
        </div>
      )}

      <button className="btn" onClick={() => setShowShare(true)} data-testid="share-btn">
        Compartir
      </button>

      {showShare && project && (
        <ShareModal project={project} onClose={() => setShowShare(false)} />
      )}
    </div>
  );
}
