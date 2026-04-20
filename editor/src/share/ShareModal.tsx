import { useState } from "react";
import type { Project } from "../domain/types";

interface Props {
  project: Project;
  onClose: () => void;
}

export function ShareModal({ project, onClose }: Props) {
  const [copied, setCopied] = useState(false);

  const exportBundle = {
    version: 1,
    exportedAt: Date.now(),
    project: {
      id: project.id,
      name: project.name,
      platform: project.platform,
    },
    flows: project.flows,
    components: project.components,
    env: project.env.map((e) => (e.secret ? { ...e, value: "" } : e)),
  };

  const bundleJson = JSON.stringify(exportBundle, null, 2);
  const shareLink = `autopilot://import#${encodeURIComponent(project.id)}`;

  function copyJson() {
    navigator.clipboard?.writeText(bundleJson);
    setCopied(true);
    setTimeout(() => setCopied(false), 1200);
  }

  function downloadJson() {
    const blob = new Blob([bundleJson], { type: "application/json" });
    const url = URL.createObjectURL(blob);
    const a = document.createElement("a");
    a.href = url;
    a.download = `${project.name.replace(/\s+/g, "-").toLowerCase()}.autopilot.json`;
    a.click();
    URL.revokeObjectURL(url);
  }

  return (
    <div className="modal-backdrop" onClick={onClose} data-testid="share-modal">
      <div className="modal" onClick={(e) => e.stopPropagation()}>
        <h2>Compartir proyecto</h2>
        <div className="field">
          <label>Link local (requiere app instalada)</label>
          <div className="share-link">
            <span style={{ flex: 1 }}>{shareLink}</span>
          </div>
        </div>
        <div className="field">
          <label>
            Export bundle · {project.flows.length} flows · {project.components.length} componentes
          </label>
          <div style={{ display: "flex", gap: 8 }}>
            <button className="btn" onClick={copyJson} data-testid="share-copy-json">
              {copied ? "Copiado ✓" : "Copiar JSON"}
            </button>
            <button className="btn" onClick={downloadJson} data-testid="share-download-json">
              Descargar .json
            </button>
          </div>
        </div>
        <div className="field">
          <label>Preview (primeros 500 chars)</label>
          <pre
            style={{
              fontSize: 10,
              background: "var(--bg-surface)",
              padding: 10,
              borderRadius: 6,
              color: "var(--text-dim)",
              maxHeight: 120,
              overflow: "auto",
              fontFamily: "JetBrains Mono, monospace",
            }}
            data-testid="share-preview"
          >
            {bundleJson.substring(0, 500)}
            {bundleJson.length > 500 ? "…" : ""}
          </pre>
        </div>
        <div className="modal-actions">
          <button className="btn btn-primary" onClick={onClose}>
            Listo
          </button>
        </div>
      </div>
    </div>
  );
}
