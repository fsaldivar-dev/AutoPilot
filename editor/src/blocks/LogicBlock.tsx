import type { Block } from "../domain/types";
import { CommandBlock } from "./CommandBlock";

interface Props {
  block: Block;
  onChildSelect?: (id: string, additive: boolean) => void;
}

export function LogicBlock({ block, onChildSelect }: Props) {
  const label = labelFor(block);
  const slots = block.slots ?? [];

  return (
    <div
      className="logic-wrapper"
      data-testid={`logic-${block.id}`}
      data-block-id={block.id}
      data-block-kind="logic"
    >
      <div className="logic-header">{label}</div>
      {slots.map((slot, si) => (
        <div key={si} className="logic-slot">
          {slot.length === 0 && (
            <div className="empty-state" style={{ padding: 8, fontSize: 11 }}>
              slot vacio — arrastra bloques aqui
            </div>
          )}
          {slot.map((b) => (
            <CommandBlock key={b.id} block={b} onSelect={onChildSelect} />
          ))}
        </div>
      ))}
    </div>
  );
}

function labelFor(block: Block): string {
  const kind = block.logicKind ?? "if";
  const args = block.args ?? {};
  switch (kind) {
    case "if":
      return `IF ${args.condition ?? "true"}`;
    case "else":
      return "ELSE";
    case "repeat":
      return `REPEAT ${args.times ?? 3} times`;
    case "foreach":
      return `FOREACH ${args.variable ?? "$item"} in ${args.list ?? "$items"}`;
    case "try":
      return "TRY";
    case "catch":
      return "CATCH";
    default:
      return String(kind).toUpperCase();
  }
}
