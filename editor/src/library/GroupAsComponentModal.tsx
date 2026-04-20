import { nanoid } from "nanoid";
import { useState } from "react";
import { useStore } from "../state/store";
import type { Block, Component, Param, Project } from "../domain/types";

interface Props {
  project: Project;
  flowId: string;
  blocks: Block[];
  onClose: () => void;
}

export function GroupAsComponentModal({
  project,
  flowId,
  blocks,
  onClose,
}: Props) {
  const detected = useState(() => detectParams(blocks))[0];
  const [name, setName] = useState("NuevoComponente");
  const [visibility, setVisibility] = useState<"private" | "workspace" | "public">("workspace");
  const addComponent = useStore((s) => s.addComponent);
  const showToast = useStore((s) => s.showToast);
  const updateFlow = useStore((s) => s.updateFlow);
  const appendBlock = useStore((s) => s.appendBlock);

  function create() {
    if (!name.trim()) return;
    const component: Component = {
      id: `cmp_${nanoid(8)}`,
      projectId: project.id,
      name: name.trim(),
      signature: detected,
      body: blocks,
      usageCount: 0,
      createdFromFlowId: flowId,
    };
    addComponent(project.id, component);

    // Replace the selected blocks in the flow with a single component-call block.
    const flow = project.flows.find((f) => f.id === flowId);
    if (flow) {
      const ids = new Set(blocks.map((b) => b.id));
      const newBlocks = flow.blocks.filter((b) => !ids.has(b.id));
      const refBlock: Block = {
        id: `blk_${nanoid(8)}`,
        kind: "component",
        command: `use ${component.name}`,
        args: { componentId: component.id },
        meta: { status: "idle" },
      };
      updateFlow(flowId, { blocks: [...newBlocks, refBlock], updatedAt: Date.now() });
    } else {
      appendBlock(flowId, {
        id: `blk_${nanoid(8)}`,
        kind: "component",
        command: `use ${component.name}`,
        args: { componentId: component.id },
        meta: { status: "idle" },
      });
    }
    showToast("ok", `Componente "${component.name}" creado · ${detected.length} parametros`);
    onClose();
  }

  return (
    <div className="modal-backdrop" onClick={onClose} data-testid="group-modal">
      <div className="modal" onClick={(e) => e.stopPropagation()}>
        <h2>Agrupar {blocks.length} bloques como componente</h2>

        <div className="field">
          <label>Nombre del componente</label>
          <input
            value={name}
            onChange={(e) => setName(e.target.value)}
            data-testid="component-name-input"
          />
        </div>

        <div className="field">
          <label>Parametros detectados ({detected.length})</label>
          {detected.length === 0 ? (
            <div style={{ color: "var(--text-dim)", fontSize: 12 }}>
              Ninguno — el componente no toma parametros.
            </div>
          ) : (
            detected.map((p) => (
              <div
                key={p.name}
                data-testid={`detected-param-${p.name}`}
                style={{
                  fontFamily: "JetBrains Mono, monospace",
                  fontSize: 12,
                  padding: "4px 0",
                  color: "var(--text-dim)",
                }}
              >
                <span style={{ color: "var(--accent)" }}>{p.name}</span>: {p.type}
                {p.secure && <span style={{ color: "var(--coral)" }}> @secure</span>}
              </div>
            ))
          )}
        </div>

        <div className="field">
          <label>Visibilidad</label>
          <select value={visibility} onChange={(e) => setVisibility(e.target.value as any)}>
            <option value="private">Private to me</option>
            <option value="workspace">Workspace</option>
            <option value="public">Public</option>
          </select>
        </div>

        <div className="modal-actions">
          <button className="btn" onClick={onClose}>
            Cancelar
          </button>
          <button className="btn btn-primary" onClick={create} data-testid="group-create-btn">
            Crear componente
          </button>
        </div>
      </div>
    </div>
  );
}

export function detectParams(blocks: Block[]): Param[] {
  const seen = new Map<string, Param>();
  const secret = /(password|secret|token|apiKey|pin)/i;
  for (const b of blocks) {
    scanValue(b.command ?? "", seen, secret);
    if (b.args) {
      for (const v of Object.values(b.args)) {
        if (typeof v === "string") scanValue(v, seen, secret);
      }
    }
  }
  return Array.from(seen.values());
}

function scanValue(text: string, seen: Map<string, Param>, secret: RegExp) {
  const re = /\$([A-Za-z_][A-Za-z0-9_.]*)/g;
  let m: RegExpExecArray | null;
  while ((m = re.exec(text)) != null) {
    const name = m[1];
    if (seen.has(name)) continue;
    seen.set(name, {
      name,
      type: "string",
      secure: secret.test(name),
    });
  }
}
