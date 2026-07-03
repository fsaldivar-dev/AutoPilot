import { describe, expect, it } from "vitest";
import type { Block, Flow } from "./types";
import { serializeFlow, parseAuto } from "./autoSerializer";

function makeFlow(blocks: Block[]): Flow {
  return { id: "f1", projectId: "p1", name: "t", blocks, updatedAt: 0 };
}
function cmd(command: string): Block {
  return { id: `b${Math.random()}`, kind: "command", command, meta: { status: "idle" } };
}

describe("autoSerializer", () => {
  describe("serialize (flow → .auto)", () => {
    it("empty flow → empty string", () => {
      expect(serializeFlow(makeFlow([]))).toBe("");
    });

    it("single command block", () => {
      expect(serializeFlow(makeFlow([cmd('tap "Login"')]))).toBe('tap "Login"');
    });

    it("multiple commands preserve order", () => {
      const out = serializeFlow(makeFlow([cmd("ping"), cmd('tap "A"')]));
      expect(out).toBe('ping\ntap "A"');
    });

    it("if without else", () => {
      const flow = makeFlow([{
        id: "x", kind: "logic", logicKind: "if",
        predicate: { kind: "call", name: "exists", args: ["Login"] },
        slots: [[cmd('tap "Login"')], []],
        meta: { status: "idle" },
      }]);
      expect(serializeFlow(flow)).toBe(
        `if exists "Login"\n  tap "Login"\nend`
      );
    });

    it("if with else", () => {
      const flow = makeFlow([{
        id: "x", kind: "logic", logicKind: "if",
        predicate: { kind: "call", name: "platform", args: ["is", "ios"] },
        slots: [[cmd('tap "iOS"')], [cmd('tap "Android"')]],
        meta: { status: "idle" },
      }]);
      expect(serializeFlow(flow)).toBe(
        `if platform is ios\n  tap "iOS"\nelse\n  tap "Android"\nend`
      );
    });

    it("repeat N times", () => {
      const flow = makeFlow([{
        id: "x", kind: "logic", logicKind: "repeat",
        repeat: { mode: "times", n: 3 },
        slots: [[cmd('tap "Next"')]],
        meta: { status: "idle" },
      }]);
      expect(serializeFlow(flow)).toBe(
        `repeat 3 times\n  tap "Next"\nend`
      );
    });

    it("repeat while", () => {
      const flow = makeFlow([{
        id: "x", kind: "logic", logicKind: "repeat",
        repeat: { mode: "while", pred: { kind: "call", name: "visible", args: ["Loader"] } },
        slots: [[cmd('wait 500')]],
        meta: { status: "idle" },
      }]);
      expect(serializeFlow(flow)).toBe(
        `repeat while visible "Loader"\n  wait 500\nend`
      );
    });

    it("repeat foreach", () => {
      const flow = makeFlow([{
        id: "x", kind: "logic", logicKind: "repeat",
        repeat: { mode: "foreach", variable: "$item", list: "$items" },
        slots: [[cmd('tap $item')]],
        meta: { status: "idle" },
      }]);
      expect(serializeFlow(flow)).toBe(
        `repeat for $item in $items\n  tap $item\nend`
      );
    });

    it("try/catch", () => {
      const flow = makeFlow([{
        id: "x", kind: "logic", logicKind: "try",
        slots: [[cmd('waitFor "Home"')], [cmd('screenshot err.png')]],
        meta: { status: "idle" },
      }]);
      expect(serializeFlow(flow)).toBe(
        `try\n  waitFor "Home"\ncatch\n  screenshot err.png\nend`
      );
    });

    it("assert", () => {
      const flow = makeFlow([{
        id: "x", kind: "logic", logicKind: "assert",
        predicate: { kind: "call", name: "visible", args: ["Home"] },
        meta: { status: "idle" },
      }]);
      expect(serializeFlow(flow)).toBe('assert visible "Home"');
    });

    it("nested if inside repeat", () => {
      const flow = makeFlow([{
        id: "r", kind: "logic", logicKind: "repeat",
        repeat: { mode: "times", n: 2 },
        slots: [[{
          id: "i", kind: "logic", logicKind: "if",
          predicate: { kind: "call", name: "exists", args: ["Ad"] },
          slots: [[cmd('tap "Close"')], []],
          meta: { status: "idle" },
        }]],
        meta: { status: "idle" },
      }]);
      expect(serializeFlow(flow)).toBe(
        `repeat 2 times\n  if exists "Ad"\n    tap "Close"\n  end\nend`
      );
    });
  });

  describe("parse (.auto → blocks)", () => {
    it("empty string → no blocks", () => {
      const r = parseAuto("");
      expect(r.blocks).toEqual([]);
      expect(r.errors).toEqual([]);
    });

    it("single command", () => {
      const r = parseAuto('tap "Login"');
      expect(r.blocks).toHaveLength(1);
      expect(r.blocks[0].kind).toBe("command");
      expect(r.blocks[0].command).toBe('tap "Login"');
    });

    it("if/else", () => {
      const r = parseAuto(`if exists "Login"\n  tap "Login"\nelse\n  tap "Register"\nend`);
      expect(r.errors).toEqual([]);
      expect(r.blocks).toHaveLength(1);
      const ib = r.blocks[0];
      expect(ib.kind).toBe("logic");
      expect(ib.logicKind).toBe("if");
      expect(ib.predicate).toEqual({ kind: "call", name: "exists", args: ["Login"] });
      expect(ib.slots?.[0]).toHaveLength(1);
      expect(ib.slots?.[1]).toHaveLength(1);
    });

    it("repeat while", () => {
      const r = parseAuto(`repeat while exists "Load"\n  wait 500\nend`);
      expect(r.errors).toEqual([]);
      const b = r.blocks[0];
      expect(b.logicKind).toBe("repeat");
      expect(b.repeat).toEqual({
        mode: "while",
        pred: { kind: "call", name: "exists", args: ["Load"] },
      });
    });

    it("assert", () => {
      const r = parseAuto(`assert visible "Home"`);
      expect(r.blocks[0].logicKind).toBe("assert");
      expect(r.blocks[0].predicate).toEqual({
        kind: "call", name: "visible", args: ["Home"],
      });
    });

    it("unclosed if → error", () => {
      const r = parseAuto(`if exists "X"\n  tap "Y"`);
      expect(r.errors.length).toBeGreaterThan(0);
      expect(r.errors[0].message).toMatch(/unclosed/i);
    });

    it("orphan end → error", () => {
      const r = parseAuto(`end`);
      expect(r.errors.length).toBeGreaterThan(0);
      expect(r.errors[0].message).toMatch(/unexpected/i);
    });
  });

  describe("roundtrip serialize→parse→serialize", () => {
    const scripts = [
      'ping',
      'tap "Login"\ntype "user"',
      `if exists "Login"\n  tap "Login"\nend`,
      `if platform is ios\n  tap "iOS"\nelse\n  tap "Android"\nend`,
      `repeat 3 times\n  tap "Next"\nend`,
      `repeat while visible "Loader"\n  wait 500\nend`,
      `try\n  waitFor "Home"\ncatch\n  screenshot err.png\nend`,
      `assert visible "Home"`,
      `repeat 2 times\n  if exists "Ad"\n    tap "Close"\n  end\nend`,
    ];
    for (const s of scripts) {
      it(`round-trips: ${s.replace(/\n/g, " · ")}`, () => {
        const { blocks, errors } = parseAuto(s);
        expect(errors).toEqual([]);
        const flow = makeFlow(blocks);
        expect(serializeFlow(flow)).toBe(s);
      });
    }
  });

  // #175 — el caso reportado en vivo: `if platform == "ios"` quedaba como
  // `if platform "==" ios` tras Aplicar. Ahora N aplicaciones (parse→serialize,
  // que es exactamente lo que hace el Aplicar de CodeView) = mismo texto.
  describe("round-trip de predicados estable (#175)", () => {
    const scripts = [
      `if platform == "ios"\n  tap "Login"\nend`,
      `if platform == "ios"\n  tap "iOS"\nelse\n  tap "Android"\nend`,
      `assert platform != "android"`,
      `repeat while count < 5\n  tap "Next"\nend`,
    ];
    for (const s of scripts) {
      it(`aplicar 3 veces = idéntico: ${s.replace(/\n/g, " · ")}`, () => {
        let current = s;
        for (let i = 0; i < 3; i++) {
          const { blocks, errors } = parseAuto(current);
          expect(errors).toEqual([]);
          current = serializeFlow(makeFlow(blocks));
          expect(current).toBe(s);
        }
      });
    }

    it("las comillas ya no migran al operador", () => {
      const { blocks, errors } = parseAuto(`if platform == "ios"\nend`);
      expect(errors).toEqual([]);
      const out = serializeFlow(makeFlow(blocks));
      expect(out).not.toContain('"=="');
      expect(out).toContain('platform == "ios"');
    });
  });
});
