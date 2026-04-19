import { useState } from "react";
import { selectCurrentProject, useStore } from "../state/store";

export function EnvChips() {
  const project = useStore(selectCurrentProject);
  const upsertEnvVar = useStore((s) => s.upsertEnvVar);
  const removeEnvVar = useStore((s) => s.removeEnvVar);
  const [showAdd, setShowAdd] = useState(false);
  const [key, setKey] = useState("");
  const [value, setValue] = useState("");
  const [scope, setScope] = useState("staging");
  const [secret, setSecret] = useState(false);

  if (!project) return null;

  const vars = project.env;

  function add() {
    if (!project || !key.trim()) return;
    upsertEnvVar(project.id, {
      projectId: project.id,
      scope,
      key: key.trim(),
      value,
      secret,
    });
    setKey("");
    setValue("");
    setSecret(false);
    setShowAdd(false);
  }

  return (
    <div data-testid="env-chips">
      <div className="section-title" style={{ display: "flex", justifyContent: "space-between" }}>
        <span>Variables</span>
        <button
          className="btn btn-icon"
          onClick={() => setShowAdd((v) => !v)}
          data-testid="env-add-btn"
        >
          +
        </button>
      </div>
      <div style={{ display: "flex", flexWrap: "wrap", gap: 4 }}>
        {vars.map((v) => (
          <div
            key={`${v.scope}:${v.key}`}
            className={`env-chip ${v.secret ? "secret" : ""}`}
            data-testid={`env-${v.key}`}
            onDoubleClick={() => removeEnvVar(project.id, v.scope, v.key)}
            title={`${v.scope} · double-click para eliminar`}
          >
            <span style={{ color: "var(--accent)" }}>${v.key}</span>
            {!v.secret && <span className="value">{v.value}</span>}
            {v.secret && <span>••••</span>}
          </div>
        ))}
        {vars.length === 0 && (
          <div style={{ color: "var(--text-mute)", fontSize: 11 }}>ninguna</div>
        )}
      </div>
      {showAdd && (
        <div style={{ marginTop: 8, display: "flex", flexDirection: "column", gap: 6 }}>
          <input
            className="modal"
            style={{ background: "var(--bg-surface)", border: "1px solid var(--border)", padding: "4px 8px", borderRadius: 6, color: "var(--text)", fontSize: 11 }}
            placeholder="key (e.g. user.email)"
            value={key}
            onChange={(e) => setKey(e.target.value)}
            data-testid="env-key-input"
          />
          <input
            style={{ background: "var(--bg-surface)", border: "1px solid var(--border)", padding: "4px 8px", borderRadius: 6, color: "var(--text)", fontSize: 11 }}
            placeholder="value"
            value={value}
            onChange={(e) => setValue(e.target.value)}
            data-testid="env-value-input"
          />
          <div style={{ display: "flex", gap: 4 }}>
            <select
              value={scope}
              onChange={(e) => setScope(e.target.value)}
              style={{ background: "var(--bg-surface)", color: "var(--text)", fontSize: 11, borderRadius: 6, border: "1px solid var(--border)", padding: "4px 8px" }}
            >
              <option value="dev">dev</option>
              <option value="staging">staging</option>
              <option value="prod">prod</option>
            </select>
            <label style={{ fontSize: 11, color: "var(--text-dim)", display: "flex", alignItems: "center", gap: 4 }}>
              <input type="checkbox" checked={secret} onChange={(e) => setSecret(e.target.checked)} /> secret
            </label>
            <button className="btn btn-primary" onClick={add} style={{ marginLeft: "auto", fontSize: 11 }} data-testid="env-save-btn">
              Guardar
            </button>
          </div>
        </div>
      )}
    </div>
  );
}
