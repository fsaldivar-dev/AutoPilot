import { nanoid } from "nanoid";
import { selectCurrentFlow, useStore } from "../state/store";
import type { Block, LogicKind } from "../domain/types";

type LogicDef = { kind: LogicKind; label: string; icon: string; slots: number };

const LOGIC: LogicDef[] = [
  { kind: "if", label: "if platform", icon: "❖", slots: 2 },
  { kind: "repeat", label: "repeat N", icon: "↻", slots: 1 },
  { kind: "foreach", label: "foreach", icon: "⎔", slots: 1 },
  { kind: "try", label: "try/catch", icon: "⚠", slots: 2 },
];

export function LogicPalette() {
  const flow = useStore(selectCurrentFlow);
  const appendBlock = useStore((s) => s.appendBlock);
  if (!flow) return null;

  function insert(def: LogicDef) {
    if (!flow) return;
    const args: Record<string, string | number | boolean> =
      def.kind === "if"
        ? { condition: 'platform == "ios"' }
        : def.kind === "repeat"
          ? { times: 3 }
          : def.kind === "foreach"
            ? { variable: "$item", list: "$items" }
            : {};

    const block: Block = {
      id: `blk_${nanoid(8)}`,
      kind: "logic",
      logicKind: def.kind,
      command: def.label,
      args,
      slots: Array.from({ length: def.slots }, () => []),
      meta: { status: "idle" },
    };
    appendBlock(flow.id, block);
  }

  return (
    <div data-testid="logic-palette">
      <div className="section-title">Logic</div>
      <div style={{ display: "flex", flexWrap: "wrap", gap: 4 }}>
        {LOGIC.map((def) => (
          <button
            key={def.kind}
            className="btn"
            onClick={() => insert(def)}
            data-testid={`logic-${def.kind}`}
            style={{
              fontSize: 11,
              fontFamily: "JetBrains Mono, monospace",
              padding: "4px 8px",
            }}
          >
            {def.icon} {def.label}
          </button>
        ))}
      </div>
    </div>
  );
}
