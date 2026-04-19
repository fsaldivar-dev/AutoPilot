import { selectCurrentFlow, useStore } from "../state/store";

export function BlockProperties() {
  const flow = useStore(selectCurrentFlow);
  const selectedIds = useStore((s) => s.selectedBlockIds);
  const updateBlock = useStore((s) => s.updateBlock);

  const blockId = selectedIds[0];
  const block = flow?.blocks.find((b) => b.id === blockId);

  if (!flow || !block) return null;

  function setArg(key: string, value: string | number | boolean) {
    if (!flow || !block) return;
    updateBlock(flow.id, block.id, {
      args: { ...(block.args ?? {}), [key]: value },
    });
  }

  return (
    <div data-testid="block-properties">
      <div className="section-title">Bloque · Propiedades</div>
      <div style={{ fontSize: 11, color: "var(--text-dim)" }}>
        <div style={{ marginBottom: 8 }}>
          <div style={{ color: "var(--text-mute)", fontSize: 10 }}>id</div>
          <div style={{ fontFamily: "JetBrains Mono, monospace", color: "var(--text)" }}>
            {block.id}
          </div>
        </div>
        <div style={{ marginBottom: 8 }}>
          <div style={{ color: "var(--text-mute)", fontSize: 10 }}>kind</div>
          <div style={{ fontFamily: "JetBrains Mono, monospace", color: "var(--text)" }}>
            {block.kind}
            {block.logicKind ? ` · ${block.logicKind}` : ""}
          </div>
        </div>
        <div style={{ marginBottom: 8 }}>
          <div style={{ color: "var(--text-mute)", fontSize: 10 }}>command</div>
          <div
            style={{
              fontFamily: "JetBrains Mono, monospace",
              color: "var(--text)",
              wordBreak: "break-all",
            }}
          >
            {block.command ?? "—"}
          </div>
        </div>
        <div style={{ marginBottom: 8 }}>
          <div style={{ color: "var(--text-mute)", fontSize: 10 }}>status</div>
          <div
            style={{
              color:
                block.meta.status === "ok"
                  ? "var(--mint)"
                  : block.meta.status === "err"
                    ? "var(--coral)"
                    : "var(--text)",
            }}
          >
            {block.meta.status}
            {block.meta.ms != null ? ` · ${block.meta.ms}ms` : ""}
          </div>
        </div>
        {block.meta.error && (
          <div style={{ marginBottom: 8 }}>
            <div style={{ color: "var(--text-mute)", fontSize: 10 }}>error</div>
            <div style={{ color: "var(--coral)" }}>{block.meta.error}</div>
          </div>
        )}

        <div className="section-title" style={{ marginTop: 16 }}>
          Ejecucion
        </div>
        <div style={{ display: "flex", flexDirection: "column", gap: 6 }}>
          <label style={{ fontSize: 11 }}>
            Timeout (ms)
            <input
              type="number"
              value={String(block.args?.timeout ?? 30000)}
              onChange={(e) => setArg("timeout", Number(e.target.value))}
              style={inputStyle}
              data-testid="prop-timeout"
            />
          </label>
          <label style={{ fontSize: 11 }}>
            Retry (veces)
            <input
              type="number"
              value={String(block.args?.retry ?? 0)}
              onChange={(e) => setArg("retry", Number(e.target.value))}
              style={inputStyle}
              data-testid="prop-retry"
            />
          </label>
          <label style={{ fontSize: 11, display: "flex", alignItems: "center", gap: 6 }}>
            <input
              type="checkbox"
              checked={!!block.args?.captureScreenshot}
              onChange={(e) => setArg("captureScreenshot", e.target.checked)}
              data-testid="prop-screenshot"
            />
            Capturar screenshot tras ejecutar
          </label>
        </div>
      </div>
    </div>
  );
}

const inputStyle: React.CSSProperties = {
  width: "100%",
  background: "var(--bg-surface)",
  border: "1px solid var(--border)",
  borderRadius: 6,
  color: "var(--text)",
  padding: "4px 6px",
  fontSize: 11,
  fontFamily: "JetBrains Mono, monospace",
  marginTop: 2,
};
