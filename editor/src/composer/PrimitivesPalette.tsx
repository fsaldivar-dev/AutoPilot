import { nanoid } from "nanoid";
import { commandsForPlatform } from "./catalog";
import { selectCurrentFlow, useStore } from "../state/store";

interface Props {
  platform: "ios" | "android" | "both";
}

const PRIMITIVES = [
  "tap",
  "type",
  "waitFor",
  "screenshot",
  "swipe",
  "clear",
  "scroll",
  "launch",
  "wait",
];

export function PrimitivesPalette({ platform }: Props) {
  const flow = useStore(selectCurrentFlow);
  const appendBlock = useStore((s) => s.appendBlock);

  if (!flow) return null;

  const runtime = platform === "android" ? "android" : "ios";
  const catalog = commandsForPlatform(runtime);
  const items = PRIMITIVES.map((name) => catalog.find((c) => c.name === name)).filter(
    (c): c is NonNullable<typeof c> => !!c
  );

  function insert(name: string) {
    if (!flow) return;
    const catalogEntry = catalog.find((c) => c.name === name);
    const template = catalogEntry?.example ?? name;
    appendBlock(flow.id, {
      id: `blk_${nanoid(8)}`,
      kind: "command",
      command: template,
      args: {},
      meta: { status: "idle" },
    });
  }

  return (
    <div data-testid="primitives-palette">
      <div className="section-title">Primitives</div>
      <div
        style={{
          display: "flex",
          flexWrap: "wrap",
          gap: 4,
        }}
      >
        {items.map((c) => (
          <button
            key={c.name}
            className="btn"
            onClick={() => insert(c.name)}
            title={c.description}
            data-testid={`primitive-${c.name}`}
            style={{
              fontSize: 11,
              fontFamily: "JetBrains Mono, monospace",
              padding: "4px 8px",
            }}
          >
            {c.name}
          </button>
        ))}
      </div>
    </div>
  );
}
