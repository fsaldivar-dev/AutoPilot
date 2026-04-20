import type { Block } from "../domain/types";
import { useStore, selectCurrentFlow } from "../state/store";
import { PredicateEditor } from "./PredicateEditor";
import { LogicSlot } from "./LogicSlot";

interface Props {
  block: Block;
  onChildSelect?: (id: string, additive: boolean) => void;
}

export function IfBlock({ block, onChildSelect }: Props) {
  const flow = useStore(selectCurrentFlow);
  const updatePredicate = useStore((s) => s.updatePredicate);

  if (!flow || !block.predicate) return null;

  const then_ = block.slots?.[0] ?? [];
  const else_ = block.slots?.[1] ?? [];

  return (
    <div
      className={`logic-wrapper logic-if status-${block.meta.status}`}
      data-testid={`if-${block.id}`}
      data-block-id={block.id}
    >
      <div className="logic-header">
        <span className="logic-keyword">if</span>
        <PredicateEditor
          value={block.predicate}
          onChange={(p) => updatePredicate(flow.id, block.id, p)}
        />
      </div>
      <LogicSlot
        parentId={block.id}
        slotIndex={0}
        label="then"
        blocks={then_}
        onChildSelect={onChildSelect}
      />
      <div className="logic-else-label">else</div>
      <LogicSlot
        parentId={block.id}
        slotIndex={1}
        label="else"
        blocks={else_}
        onChildSelect={onChildSelect}
      />
    </div>
  );
}
