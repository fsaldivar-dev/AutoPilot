import type { Block, RepeatMode } from "../domain/types";
import { useStore, selectCurrentFlow } from "../state/store";
import { PredicateEditor } from "./PredicateEditor";
import { LogicSlot } from "./LogicSlot";

interface Props {
  block: Block;
  onChildSelect?: (id: string, additive: boolean) => void;
}

export function RepeatBlock({ block, onChildSelect }: Props) {
  const flow = useStore(selectCurrentFlow);
  const updateRepeat = useStore((s) => s.updateRepeat);
  if (!flow || !block.repeat) return null;

  const body = block.slots?.[0] ?? [];
  const r = block.repeat;

  function setMode(mode: RepeatMode["mode"]) {
    if (!flow) return;
    let next: RepeatMode;
    switch (mode) {
      case "times":   next = { mode: "times", n: 3 }; break;
      case "while":   next = { mode: "while", pred: { kind: "call", name: "exists", args: ["..."] } }; break;
      case "until":   next = { mode: "until", pred: { kind: "call", name: "exists", args: ["..."] } }; break;
      case "foreach": next = { mode: "foreach", variable: "$item", list: "$items" }; break;
    }
    updateRepeat(flow.id, block.id, next);
  }

  return (
    <div
      className={`logic-wrapper logic-repeat status-${block.meta.status}`}
      data-testid={`repeat-${block.id}`}
      data-block-id={block.id}
    >
      <div className="logic-header">
        <span className="drag-handle" title="Arrastrar para reordenar" aria-hidden>⋮⋮</span>
        <span className="logic-keyword">repeat</span>
        <select
          className="repeat-mode-select"
          value={r.mode}
          onChange={(e) => setMode(e.target.value as RepeatMode["mode"])}
          data-testid="repeat-mode"
        >
          <option value="times">N times</option>
          <option value="while">while</option>
          <option value="until">until</option>
          <option value="foreach">for each</option>
        </select>

        {r.mode === "times" && (
          <input
            type="number"
            min={0}
            className="repeat-n-input"
            value={r.n}
            onChange={(e) => {
              const n = parseInt(e.target.value, 10);
              if (Number.isFinite(n)) updateRepeat(flow!.id, block.id, { mode: "times", n });
            }}
            data-testid="repeat-n"
          />
        )}
        {r.mode === "while" && (
          <PredicateEditor
            value={r.pred}
            onChange={(pred) => updateRepeat(flow!.id, block.id, { mode: "while", pred })}
          />
        )}
        {r.mode === "until" && (
          <PredicateEditor
            value={r.pred}
            onChange={(pred) => updateRepeat(flow!.id, block.id, { mode: "until", pred })}
          />
        )}
        {r.mode === "foreach" && (
          <>
            <input
              className="repeat-var-input"
              value={r.variable}
              onChange={(e) =>
                updateRepeat(flow!.id, block.id, { ...r, variable: e.target.value })
              }
              placeholder="$item"
            />
            <span className="logic-keyword">in</span>
            <input
              className="repeat-var-input"
              value={r.list}
              onChange={(e) => updateRepeat(flow!.id, block.id, { ...r, list: e.target.value })}
              placeholder="$items"
            />
          </>
        )}
      </div>
      <LogicSlot
        parentId={block.id}
        slotIndex={0}
        label="body"
        blocks={body}
        onChildSelect={onChildSelect}
      />
    </div>
  );
}
