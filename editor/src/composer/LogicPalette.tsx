import { nanoid } from "nanoid";
import { selectCurrentFlow, useStore } from "../state/store";
import type { Block, LogicKind } from "../domain/types";

type LogicDef = { kind: "if" | "repeat" | "foreach" | "try"; label: string; icon: string };

const LOGIC: LogicDef[] = [
  { kind: "if", label: "if platform", icon: "❖" },
  { kind: "repeat", label: "repeat N", icon: "↻" },
  { kind: "foreach", label: "foreach", icon: "⎔" },
  { kind: "try", label: "try/catch", icon: "⚠" },
];

// Construye el bloque estructural que el serializer y el canvas entienden:
// - if      → `predicate` (NO `args.condition` — el serializer lee b.predicate
//             y IfBlock no renderiza sin él; era el bug #175: if inválido e
//             invisible) + slots [then, else]
// - repeat  → `repeat: { mode: "times" }` + slot [body]
// - foreach → logicKind "repeat" con `repeat: { mode: "foreach" }` ("foreach"
//             como logicKind es legacy: el serializer lo ignora en silencio)
// - try     → slots [body, catch]
function makeLogicBlock(def: LogicDef): Block {
  let logicKind: LogicKind;
  let partial: Partial<Block>;
  switch (def.kind) {
    case "if":
      logicKind = "if";
      partial = {
        predicate: { kind: "call", name: "platform", args: ["is", "ios"] },
        slots: [[], []],
      };
      break;
    case "repeat":
      logicKind = "repeat";
      partial = { repeat: { mode: "times", n: 3 }, slots: [[]] };
      break;
    case "foreach":
      logicKind = "repeat";
      partial = {
        repeat: { mode: "foreach", variable: "$item", list: "$items" },
        slots: [[]],
      };
      break;
    case "try":
      logicKind = "try";
      partial = { slots: [[], []] };
      break;
  }
  return {
    id: `${logicKind}_${nanoid(8)}`,
    kind: "logic",
    logicKind,
    ...partial,
    meta: { status: "idle" },
  };
}

export function LogicPalette() {
  const flow = useStore(selectCurrentFlow);
  const appendBlock = useStore((s) => s.appendBlock);
  if (!flow) return null;

  function insert(def: LogicDef) {
    if (!flow) return;
    appendBlock(flow.id, makeLogicBlock(def));
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

// Exportado para tests.
export { makeLogicBlock, LOGIC };
export type { LogicDef };
