import { useMemo, useState } from "react";
import { CommandBar } from "./CommandBar";
import { CommandBlock } from "../blocks/CommandBlock";
import { ComponentBlock } from "../blocks/ComponentBlock";
import { LogicBlock } from "../blocks/LogicBlock";
import { selectCurrentFlow, selectCurrentProject, useStore } from "../state/store";
import { GroupAsComponentModal } from "../library/GroupAsComponentModal";
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

  const [showGroupModal, setShowGroupModal] = useState(false);

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
        flow.blocks.map((b) => renderBlock(b, project?.components ?? [], selectedIds, onSelect, onDelete))
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
  onDelete: (id: string) => void
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
    />
  );
}
