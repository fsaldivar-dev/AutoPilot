import { useMemo, useState } from "react";
import { CommandBar } from "./CommandBar";
import { InlineCommandEditor } from "./InlineCommandEditor";
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
  const moveBlock = useStore((s) => s.moveBlock);
  const sessionId = useStore((s) => s.sessionId);
  const setSession = useStore((s) => s.setSession);
  const running = useStore((s) => s.running);
  const setRunning = useStore((s) => s.setRunning);
  const showToast = useStore((s) => s.showToast);

  const [showGroupModal, setShowGroupModal] = useState(false);
  const [draggingId, setDraggingId] = useState<string | null>(null);
  const [dragOverIndex, setDragOverIndex] = useState<number | null>(null);
  const [editingId, setEditingId] = useState<string | null>(null);

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

  function onDragStart(e: React.DragEvent, id: string) {
    setDraggingId(id);
    e.dataTransfer.effectAllowed = "move";
    e.dataTransfer.setData("text/x-block-id", id);
    // Opaque drag image — otherwise Chrome shows the handle only
    const target = (e.currentTarget as HTMLElement).closest(".block-wrapper");
    if (target) e.dataTransfer.setDragImage(target, 20, 20);
  }
  function onDragEnd() {
    setDraggingId(null);
    setDragOverIndex(null);
  }
  // Drop zone is the block itself — top half inserts before, bottom half after.
  function onDragOverBlock(e: React.DragEvent, blockIdx: number) {
    if (!draggingId) return;
    e.preventDefault();
    e.dataTransfer.dropEffect = "move";
    const rect = (e.currentTarget as HTMLElement).getBoundingClientRect();
    const isTopHalf = e.clientY - rect.top < rect.height / 2;
    setDragOverIndex(isTopHalf ? blockIdx : blockIdx + 1);
  }
  function onDropBlock(e: React.DragEvent) {
    e.preventDefault();
    const id = e.dataTransfer.getData("text/x-block-id") || draggingId;
    if (!id || !flow || dragOverIndex == null) {
      setDraggingId(null);
      setDragOverIndex(null);
      return;
    }
    const fromIdx = flow.blocks.findIndex((b) => b.id === id);
    if (fromIdx < 0) return;
    let target = dragOverIndex;
    if (fromIdx < dragOverIndex) target = dragOverIndex - 1;
    if (target !== fromIdx) moveBlock(flow.id, id, target);
    setDraggingId(null);
    setDragOverIndex(null);
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
    <div className="canvas" data-testid="block-canvas">
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
          {flow.blocks.map((b, idx) => {
            const showInsertBefore = dragOverIndex === idx && draggingId && draggingId !== b.id;
            const showInsertAfter = dragOverIndex === idx + 1 && draggingId && draggingId !== b.id && idx === flow.blocks.length - 1;
            const isEditing = editingId === b.id;
            return (
              <div key={b.id}>
                {showInsertBefore && <div className="drop-indicator" />}
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
                    className={`block-wrapper${draggingId === b.id ? " block-dragging" : ""}`}
                    draggable={b.kind !== "logic"}
                    onDragStart={(e) => onDragStart(e, b.id)}
                    onDragEnd={onDragEnd}
                    onDragOver={(e) => onDragOverBlock(e, idx)}
                    onDrop={onDropBlock}
                    onDoubleClick={(e) => {
                      e.stopPropagation();
                      if (b.kind === "command") onEditStart(b.id);
                    }}
                    onDragLeave={(e) => {
                      const to = e.relatedTarget as Node | null;
                      if (!to || !(e.currentTarget as HTMLElement).contains(to)) {
                        if (dragOverIndex === idx || dragOverIndex === idx + 1) {
                          setDragOverIndex(null);
                        }
                      }
                    }}
                  >
                    {renderBlock(b, project?.components ?? [], selectedIds, onSelect, onDelete, onRunBlock, onEditStart, !running)}
                  </div>
                )}
                {showInsertAfter && <div className="drop-indicator" />}
              </div>
            );
          })}
        </>
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
