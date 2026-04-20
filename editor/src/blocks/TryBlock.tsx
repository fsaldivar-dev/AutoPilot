import type { Block } from "../domain/types";
import { LogicSlot } from "./LogicSlot";

interface Props {
  block: Block;
  onChildSelect?: (id: string, additive: boolean) => void;
}

export function TryBlock({ block, onChildSelect }: Props) {
  const body = block.slots?.[0] ?? [];
  const catch_ = block.slots?.[1] ?? [];

  return (
    <div
      className={`logic-wrapper logic-try status-${block.meta.status}`}
      data-testid={`try-${block.id}`}
      data-block-id={block.id}
    >
      <div className="logic-header">
        <span className="logic-keyword">try</span>
      </div>
      <LogicSlot
        parentId={block.id}
        slotIndex={0}
        label="body"
        blocks={body}
        onChildSelect={onChildSelect}
      />
      <div className="logic-else-label">catch</div>
      <LogicSlot
        parentId={block.id}
        slotIndex={1}
        label="catch"
        blocks={catch_}
        onChildSelect={onChildSelect}
      />
    </div>
  );
}
