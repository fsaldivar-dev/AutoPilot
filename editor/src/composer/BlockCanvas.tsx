import { useMemo, useRef, useState } from "react";
import { CommandBar } from "./CommandBar";
import { InlineCommandEditor } from "./InlineCommandEditor";
import { useBlockDrag } from "./useBlockDrag";
import { CommandBlock } from "../blocks/CommandBlock";
import { ComponentBlock } from "../blocks/ComponentBlock";
import { LogicBlock } from "../blocks/LogicBlock";
import { selectCurrentFlow, selectCurrentProject, useStore } from "../state/store";
import { GroupAsComponentModal } from "../library/GroupAsComponentModal";
import { runBlock } from "../services/flowRunner";
import type { Block, Platform } from "../domain/types";

interface Props {
  platform: Platform;
}

export function BlockCanvas({ platform }: Props) {
  const flow = useStore(selectCurrentFlow);
  const project = useStore(selectCurrentProject);
  const selectedIds = useStore((s) => s.selectedBlockIds);
  const setSelected = useStore((s) => s.setSelectedBlocks);
  const removeBlock = useStore((s) => s.removeBlock);
  const updateBlock = useStore((s) => s.updateBlock);
  const moveBlockToTarget = useStore((s) => s.moveBlockToTarget);
  const sessionId = useStore((s) => s.sessionId);
  const setSession = useStore((s) => s.setSession);
  const running = useStore((s) => s.running);
  const setRunning = useStore((s) => s.setRunning);
  const showToast = useStore((s) => s.showToast);
  const bumpRefreshTick = useStore((s) => s.bumpRefreshTick);

  const [showGroupModal, setShowGroupModal] = useState(false);
  const [editingId, setEditingId] = useState<string | null>(null);

  const canvasRef = useRef<HTMLDivElement>(null);
  const flowIdRef = useRef<string | undefined>(flow?.id);
  flowIdRef.current = flow?.id;
  const { draggingId, indicator, onPointerDown } = useBlockDrag(canvasRef, {
    enabled: !running && editingId == null,
    onDrop: (blockId, dest) => {
      if (flowIdRef.current) moveBlockToTarget(flowIdRef.current, blockId, dest);
    },
  });

  const selectedBlocks = useMemo(
    () => (flow?.blocks ?? []).filter((b) => selectedIds.includes(b.id)),
    [flow, selectedIds]
  );

  function onSelect(id: string, additive: boolean) {
    if (additive) {
      setSelected(
        selectedIds.includes(id)
          ? selectedIds.filter((x) => x !== id)
          : [...selectedIds, id]
      );
    } else {
      setSelected([id]);
    }
  }

  function onDelete(id: string) {
    if (!flow) return;
    removeBlock(flow.id, id);
    setSelected(selectedIds.filter((x) => x !== id));
  }

  function onEditStart(id: string) {
    if (running) return;
    setEditingId(id);
  }
  function onEditSave(id: string, newCommand: string) {
    if (!flow) return;
    updateBlock(flow.id, id, { command: newCommand, meta: { status: "idle" } });
    setEditingId(null);
  }
  function onEditCancel() {
    setEditingId(null);
  }

  async function onRunBlock(id: string) {
    if (!flow || !project || running) return;
    const block = flow.blocks.find((b) => b.id === id);
    if (!block) return;
    const runtime = platform === "android" ? "android" : "ios";

    setRunning(true);
    try {
      await runBlock(sessionId, runtime, block, project.env, {
        onStart: () => {
          updateBlock(flow.id, id, { meta: { status: "running", ranAt: Date.now() } });
        },
        onEnd: (ok, ms, err) => {
          updateBlock(flow.id, id, {
            meta: { status: ok ? "ok" : "err", ms, error: err, ranAt: Date.now() },
          });
          if (!ok && err) showToast("err", `✗ ${err}`);
        },
        onSessionChange: (newSid) => setSession(newSid, runtime),
        onUIMutation: () => bumpRefreshTick(),
      });
    } finally {
      setRunning(false);
    }
  }

  if (!flow) {
    return (
      <div className="canvas">
        <div className="empty-state">
          <div style={{ fontSize: 48, marginBottom: 16 }}>✨</div>
          <div>Selecciona un proyecto y un flow para empezar</div>
          <div className="hint">
            Usa el boton + en el panel izquierdo para crear uno nuevo
          </div>
        </div>
      </div>
    );
  }

  return (
    <div
      className="canvas"
      data-testid="block-canvas"
      data-drop-root
      ref={canvasRef}
      onPointerDown={onPointerDown}
    >
      <CommandBar platform={platform} />

      {selectedBlocks.length >= 2 && (
        <div
          className="block"
          style={{ justifyContent: "center", borderColor: "var(--accent)", background: "rgba(139, 92, 246, 0.08)" }}
          data-testid="group-toolbar"
        >
          <span style={{ color: "var(--accent)", fontWeight: 600, fontSize: 12 }}>
            {selectedBlocks.length} bloques seleccionados
          </span>
          <div className="block-actions">
            <button
              className="btn btn-primary"
              onClick={() => setShowGroupModal(true)}
              data-testid="group-as-component-btn"
            >
              Agrupar como componente
            </button>
          </div>
        </div>
      )}

      {flow.blocks.length === 0 ? (
        <div className="empty-state">
          <div>Sin bloques todavia</div>
          <div className="hint">Tipea un comando arriba y presiona Enter</div>
        </div>
      ) : (
        <>
          {flow.blocks.map((b) => {
            const isEditing = editingId === b.id;
            return (
              <div key={b.id}>
                {isEditing ? (
                  <div onDoubleClick={(e) => e.stopPropagation()}>
                    <InlineCommandEditor
                      initial={b.command ?? ""}
                      platform={platform === "android" ? "android" : "ios"}
                      onSave={(newCmd) => onEditSave(b.id, newCmd)}
                      onCancel={onEditCancel}
                    />
                  </div>
                ) : (
                  <div
                    className="block-wrapper"
                    onDoubleClick={(e) => {
                      e.stopPropagation();
                      if (b.kind === "command") onEditStart(b.id);
                    }}
                  >
                    {renderBlock(b, project?.components ?? [], selectedIds, onSelect, onDelete, onRunBlock, onEditStart, !running)}
                  </div>
                )}
              </div>
            );
          })}
        </>
      )}

      {draggingId && indicator && (
        <div
          className="dnd-indicator"
          data-testid="dnd-indicator"
          style={{ top: indicator.top, left: indicator.left, width: indicator.width }}
        />
      )}

      {showGroupModal && project && (
        <GroupAsComponentModal
          project={project}
          flowId={flow.id}
          blocks={selectedBlocks}
          onClose={() => setShowGroupModal(false)}
        />
      )}
    </div>
  );
}

function renderBlock(
  b: Block,
  components: import("../domain/types").Component[],
  selectedIds: string[],
  onSelect: (id: string, additive: boolean) => void,
  onDelete: (id: string) => void,
  onRun: (id: string) => void,
  onEdit: (id: string) => void,
  canRun: boolean
): React.ReactNode {
  if (b.kind === "logic") {
    return <LogicBlock key={b.id} block={b} onChildSelect={onSelect} />;
  }
  if (b.kind === "component") {
    const comp = components.find((c) => c.id === (b.args?.componentId as string));
    return (
      <ComponentBlock
        key={b.id}
        block={b}
        component={comp}
        selected={selectedIds.includes(b.id)}
        onSelect={onSelect}
        onDelete={onDelete}
      />
    );
  }
  return (
    <CommandBlock
      key={b.id}
      block={b}
      selected={selectedIds.includes(b.id)}
      onSelect={onSelect}
      onDelete={onDelete}
      onRun={onRun}
      onEdit={onEdit}
      canRun={canRun}
    />
  );
}
