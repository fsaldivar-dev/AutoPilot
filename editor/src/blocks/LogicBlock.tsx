import type { Block } from "../domain/types";
import { CommandBlock } from "./CommandBlock";
import { IfBlock } from "./IfBlock";
import { RepeatBlock } from "./RepeatBlock";
import { TryBlock } from "./TryBlock";
import { AssertBlock } from "./AssertBlock";

interface Props {
  block: Block;
  onChildSelect?: (id: string, additive: boolean) => void;
}

// Router que despacha por logicKind. Casos legacy (else/catch/foreach suelto)
// caen al fallback LegacyLogicBlock — renderiza como antes sin crashear.
export function LogicBlock({ block, onChildSelect }: Props) {
  switch (block.logicKind) {
    case "if":     return <IfBlock block={block} onChildSelect={onChildSelect} />;
    case "repeat": return <RepeatBlock block={block} onChildSelect={onChildSelect} />;
    case "try":    return <TryBlock block={block} onChildSelect={onChildSelect} />;
    case "assert": return <AssertBlock block={block} />;
    default:       return <LegacyLogicBlock block={block} onChildSelect={onChildSelect} />;
  }
}

// Fallback para flows persistidos con logicKind legacy o mal formados.
function LegacyLogicBlock({ block, onChildSelect }: Props) {
  const label = labelFor(block);
  const slots = block.slots ?? [];

  return (
    <div
      className="logic-wrapper logic-legacy"
      data-testid={`logic-${block.id}`}
      data-block-id={block.id}
      data-block-kind="logic"
    >
      <div className="logic-header">{label}</div>
      {slots.map((slot, si) => (
        <div key={si} className="logic-slot">
          {slot.length === 0 && (
            <div className="slot-placeholder">slot vacío (legacy)</div>
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
    case "if":      return `IF ${args.condition ?? "true"}`;
    case "else":    return "ELSE";
    case "repeat":  return `REPEAT ${args.times ?? 3} times`;
    case "foreach": return `FOREACH ${args.variable ?? "$item"} in ${args.list ?? "$items"}`;
    case "try":     return "TRY";
    case "catch":   return "CATCH";
    default:        return String(kind).toUpperCase();
  }
}
