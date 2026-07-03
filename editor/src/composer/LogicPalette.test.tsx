import { beforeEach, describe, expect, it } from "vitest";
import { render, screen } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { useStore } from "../state/store";
import { LogicPalette } from "./LogicPalette";
import { LogicBlock } from "../blocks/LogicBlock";
import { serializeFlow } from "../domain/autoSerializer";

// #175 — el chip "if platform" guardaba la condición en args.condition, pero
// el serializer lee b.predicate y IfBlock no renderiza sin predicate: el
// bloque contaba (+1) pero era invisible en canvas y salía `if`/`end` pelado
// con 1 error en la vista Código. Estos tests fijan el contrato: cada chip
// produce un bloque estructural válido (predicate/repeat/slots), visible y
// serializable sin errores.

function seedProjectAndFlow() {
  useStore.setState({
    projects: [
      {
        id: "p1",
        name: "Demo",
        platform: "ios",
        flows: [
          {
            id: "f1",
            projectId: "p1",
            name: "Flow 1",
            blocks: [],
            updatedAt: Date.now(),
          },
        ],
        components: [],
        env: [],
        devices: [],
        createdAt: Date.now(),
        updatedAt: Date.now(),
      },
    ],
    currentProjectId: "p1",
    currentFlowId: "f1",
    selectedBlockIds: [],
    sessionId: undefined,
    running: false,
    elements: [],
    recentBlocks: [],
  });
}

function currentFlow() {
  return useStore.getState().projects[0].flows[0];
}

describe("LogicPalette (#175)", () => {
  beforeEach(() => {
    seedProjectAndFlow();
  });

  it("chip 'if platform' crea un if con predicate real y slots then/else", async () => {
    const user = userEvent.setup();
    render(<LogicPalette />);
    await user.click(screen.getByTestId("logic-if"));

    const blocks = currentFlow().blocks;
    expect(blocks).toHaveLength(1);
    const b = blocks[0];
    expect(b.kind).toBe("logic");
    expect(b.logicKind).toBe("if");
    // El bug: la condición vivía en args.condition y predicate quedaba undefined.
    expect(b.predicate).toEqual({ kind: "call", name: "platform", args: ["is", "ios"] });
    expect(b.slots).toEqual([[], []]);
    expect(b.args).toBeUndefined();
  });

  it("el if del chip es VISIBLE en el canvas (IfBlock renderiza)", async () => {
    const user = userEvent.setup();
    render(<LogicPalette />);
    await user.click(screen.getByTestId("logic-if"));

    const b = currentFlow().blocks[0];
    render(<LogicBlock block={b} />);
    // Antes: IfBlock devolvía null (sin predicate) → contador subía pero no
    // se veía nada.
    expect(screen.getByTestId(`if-${b.id}`)).toBeInTheDocument();
  });

  it("el if del chip serializa a código válido (no `if`/`end` pelado)", async () => {
    const user = userEvent.setup();
    render(<LogicPalette />);
    await user.click(screen.getByTestId("logic-if"));

    expect(serializeFlow(currentFlow())).toBe("if platform is ios\nend");
  });

  it("chip 'repeat N' crea repeat con modo times (no args.times)", async () => {
    const user = userEvent.setup();
    render(<LogicPalette />);
    await user.click(screen.getByTestId("logic-repeat"));

    const b = currentFlow().blocks[0];
    expect(b.logicKind).toBe("repeat");
    expect(b.repeat).toEqual({ mode: "times", n: 3 });
    expect(serializeFlow(currentFlow())).toBe("repeat 3 times\nend");

    render(<LogicBlock block={b} />);
    expect(screen.getByTestId(`repeat-${b.id}`)).toBeInTheDocument();
  });

  it("chip 'foreach' crea repeat con modo foreach (no logicKind legacy)", async () => {
    const user = userEvent.setup();
    render(<LogicPalette />);
    await user.click(screen.getByTestId("logic-foreach"));

    const b = currentFlow().blocks[0];
    // "foreach" como logicKind es legacy y el serializer lo ignoraba: bloque
    // fantasma. Ahora es un repeat estructural con modo foreach.
    expect(b.logicKind).toBe("repeat");
    expect(b.repeat).toEqual({ mode: "foreach", variable: "$item", list: "$items" });
    expect(serializeFlow(currentFlow())).toBe("repeat for $item in $items\nend");
  });

  it("chip 'try/catch' crea try con slots body/catch", async () => {
    const user = userEvent.setup();
    render(<LogicPalette />);
    await user.click(screen.getByTestId("logic-try"));

    const b = currentFlow().blocks[0];
    expect(b.logicKind).toBe("try");
    expect(b.slots).toEqual([[], []]);
    expect(serializeFlow(currentFlow())).toBe("try\nend");
  });

  it("todos los chips producen bloques que round-trippean sin errores", async () => {
    const user = userEvent.setup();
    render(<LogicPalette />);
    for (const kind of ["if", "repeat", "foreach", "try"]) {
      await user.click(screen.getByTestId(`logic-${kind}`));
    }
    const text = serializeFlow(currentFlow());
    const { parseAuto } = await import("../domain/autoSerializer");
    const { errors, blocks } = parseAuto(text);
    expect(errors).toEqual([]);
    expect(blocks).toHaveLength(4);
    // Estable: re-serializar da el mismo texto.
    const flow2 = { ...currentFlow(), blocks };
    expect(serializeFlow(flow2)).toBe(text);
  });
});
