import { useState } from "react";
import { nanoid } from "nanoid";
import type { Block } from "../domain/types";
import { useStore, selectCurrentFlow } from "../state/store";
import { CommandBlock } from "./CommandBlock";
import { LogicBlock } from "./LogicBlock";

interface Props {
  parentId: string;
  slotIndex: number;
  label: string;
  blocks: Block[];
  onChildSelect?: (id: string, additive: boolean) => void;
}

// Renderiza un slot de logic block (then/else/body/catch). Muestra placeholder
// si está vacío + botón `+ child` que abre un input inline para agregar
// comandos/logic anidados.
export function LogicSlot({ parentId, slotIndex, label, blocks, onChildSelect }: Props) {
  const flow = useStore(selectCurrentFlow);
  const addChildBlock = useStore((s) => s.addChildBlock);
  const removeChildBlock = useStore((s) => s.removeChildBlock);
  const [adding, setAdding] = useState(false);
  const [draft, setDraft] = useState("");

  function commit() {
    const trimmed = draft.trim();
    if (!trimmed || !flow) {
      setAdding(false);
      setDraft("");
      return;
    }
    const block: Block = {
      id: `blk_${nanoid(8)}`,
      kind: "command",
      command: trimmed,
      meta: { status: "idle" },
    };
    addChildBlock(flow.id, parentId, slotIndex, block);
    setDraft("");
    setAdding(false);
  }

  function onDelete(childId: string) {
    if (!flow) return;
    removeChildBlock(flow.id, parentId, slotIndex, childId);
  }

  return (
    <div
      className="logic-slot"
      data-slot={label}
      data-testid={`slot-${parentId}-${slotIndex}`}
      data-drop-parent={parentId}
      data-drop-slot={slotIndex}
    >
      {blocks.length === 0 && !adding && (
        <div className="slot-placeholder">slot vacío — click + para agregar</div>
      )}
      {blocks.map((b) =>
        b.kind === "logic" ? (
          <LogicBlock key={b.id} block={b} onChildSelect={onChildSelect} />
        ) : (
          <CommandBlock
            key={b.id}
            block={b}
            onSelect={onChildSelect}
            onDelete={onDelete}
          />
        )
      )}
      {adding ? (
        <div className="slot-add-row">
          <input
            autoFocus
            className="slot-add-input"
            value={draft}
            onChange={(e) => setDraft(e.target.value)}
            onBlur={commit}
            onKeyDown={(e) => {
              if (e.key === "Enter") commit();
              if (e.key === "Escape") {
                setDraft("");
                setAdding(false);
              }
            }}
            placeholder='tap "..."'
          />
        </div>
      ) : (
        <button
          className="slot-add-btn"
          onClick={() => setAdding(true)}
          data-testid={`slot-add-${parentId}-${slotIndex}`}
        >
          + child
        </button>
      )}
    </div>
  );
}
