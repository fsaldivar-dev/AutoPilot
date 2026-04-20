import { afterEach, describe, expect, it, vi } from "vitest";
import type { Block, Flow, Predicate } from "../domain/types";

// Mock del módulo executor antes de importar flowRunner.
const sendMock = vi.fn();
vi.mock("./executor", () => ({
  sendWithRecover: (_p: string, sid: string | undefined, line: string) =>
    sendMock(sid, line),
  send: () => { throw new Error("unused"); },
  spawn: () => { throw new Error("unused"); },
  kill: () => { throw new Error("unused"); },
  status: () => { throw new Error("unused"); },
}));

import { runFlow } from "./flowRunner";

afterEach(() => {
  sendMock.mockReset();
});

function cmd(id: string, command: string): Block {
  return { id, kind: "command", command, meta: { status: "idle" } };
}
function makeFlow(blocks: Block[]): Flow {
  return { id: "f1", projectId: "p1", name: "t", blocks, updatedAt: 0 };
}
function ifBlock(id: string, pred: Predicate, then_: Block[], else_: Block[] = []): Block {
  return {
    id, kind: "logic", logicKind: "if",
    predicate: pred, slots: [then_, else_],
    meta: { status: "idle" },
  };
}
function repeatTimes(id: string, n: number, body: Block[]): Block {
  return {
    id, kind: "logic", logicKind: "repeat",
    repeat: { mode: "times", n },
    slots: [body],
    meta: { status: "idle" },
  };
}
function tryBlock(id: string, body: Block[], catch_: Block[]): Block {
  return {
    id, kind: "logic", logicKind: "try",
    slots: [body, catch_],
    meta: { status: "idle" },
  };
}

// Helper: devuelve una respuesta OK con `out` opcional.
function okFrame(out?: string) {
  return { ok: true, ms: 1, out } as any;
}
function errFrame(err = "boom") {
  return { ok: false, ms: 1, err } as any;
}

function mkCb() {
  const started: string[] = [];
  const ended: { id: string; ok: boolean }[] = [];
  return {
    started, ended,
    onBlockStart: (id: string) => started.push(id),
    onBlockEnd: (id: string, ok: boolean) => ended.push({ id, ok }),
    shouldAbortOnError: () => true,
  };
}

describe("flowRunner control flow", () => {
  it("executes flat commands", async () => {
    sendMock.mockImplementation(async (sid, _line) => ({
      frame: okFrame(), sessionId: sid ?? "s1",
    }));
    const flow = makeFlow([cmd("a", 'tap "A"'), cmd("b", 'tap "B"')]);
    const cb = mkCb();
    const r = await runFlow("s1", "ios", flow, [], cb);
    expect(r.ok).toBe(true);
    expect(r.ran).toBe(2);
    expect(cb.ended.map(e => e.id)).toEqual(["a", "b"]);
  });

  it("if true-branch runs then, skips else", async () => {
    sendMock.mockImplementation(async (sid, line) => {
      if (line.startsWith("exists")) return { frame: okFrame("YES (1ms)"), sessionId: sid };
      return { frame: okFrame(), sessionId: sid };
    });
    const flow = makeFlow([
      ifBlock("ifA",
        { kind: "call", name: "exists", args: ["X"] },
        [cmd("t", 'tap "T"')],
        [cmd("e", 'tap "E"')],
      ),
    ]);
    const cb = mkCb();
    await runFlow("s1", "ios", flow, [], cb);
    const taps = sendMock.mock.calls.filter(c => String(c[1]).startsWith("tap "));
    expect(taps).toHaveLength(1);
    expect(taps[0][1]).toBe('tap "T"');
  });

  it("if false-branch runs else", async () => {
    sendMock.mockImplementation(async (sid, line) => {
      if (line.startsWith("exists")) return { frame: okFrame("NO (1ms)"), sessionId: sid };
      return { frame: okFrame(), sessionId: sid };
    });
    const flow = makeFlow([
      ifBlock("ifA",
        { kind: "call", name: "exists", args: ["X"] },
        [cmd("t", 'tap "T"')],
        [cmd("e", 'tap "E"')],
      ),
    ]);
    await runFlow("s1", "ios", flow, [], mkCb());
    const taps = sendMock.mock.calls.filter(c => String(c[1]).startsWith("tap "));
    expect(taps).toHaveLength(1);
    expect(taps[0][1]).toBe('tap "E"');
  });

  it("platform is ios short-circuits (no CLI roundtrip)", async () => {
    sendMock.mockImplementation(async (sid) => ({ frame: okFrame(), sessionId: sid }));
    const flow = makeFlow([
      ifBlock("p",
        { kind: "call", name: "platform", args: ["is", "ios"] },
        [cmd("t", 'tap "T"')],
      ),
    ]);
    await runFlow("s1", "ios", flow, [], mkCb());
    // Solo debería haberse enviado tap — NO `platform` como comando.
    const lines = sendMock.mock.calls.map(c => String(c[1]));
    expect(lines).toEqual(['tap "T"']);
  });

  it("repeat N times runs body N veces", async () => {
    sendMock.mockImplementation(async (sid) => ({ frame: okFrame(), sessionId: sid }));
    const flow = makeFlow([repeatTimes("r", 3, [cmd("t", 'tap "Next"')])]);
    await runFlow("s1", "ios", flow, [], mkCb());
    expect(sendMock.mock.calls.filter(c => c[1] === 'tap "Next"')).toHaveLength(3);
  });

  it("try/catch recupera cuando body falla", async () => {
    sendMock.mockImplementation(async (sid, line) => {
      if (line.startsWith('tap "F"')) return { frame: errFrame("not found"), sessionId: sid };
      return { frame: okFrame(), sessionId: sid };
    });
    const flow = makeFlow([
      tryBlock("t", [cmd("fail", 'tap "F"')], [cmd("rec", 'screenshot err.png')]),
      cmd("after", 'ping'),
    ]);
    const cb = mkCb();
    await runFlow("s1", "ios", flow, [], cb);
    const lines = sendMock.mock.calls.map(c => String(c[1]));
    expect(lines).toContain('tap "F"');
    expect(lines).toContain('screenshot err.png');
    expect(lines).toContain('ping');
  });

  it("and short-circuits on false", async () => {
    sendMock.mockImplementation(async (sid, line) => {
      if (line === 'exists "A"') return { frame: okFrame("NO (1ms)"), sessionId: sid };
      return { frame: okFrame(), sessionId: sid };
    });
    const pred: Predicate = {
      kind: "and",
      left: { kind: "call", name: "exists", args: ["A"] },
      right: { kind: "call", name: "exists", args: ["B"] },
    };
    const flow = makeFlow([ifBlock("p", pred, [cmd("t", 'tap "T"')])]);
    await runFlow("s1", "ios", flow, [], mkCb());
    const existsLines = sendMock.mock.calls.filter(c => String(c[1]).startsWith("exists"));
    // Solo se evalúa A; B se short-circuita.
    expect(existsLines).toHaveLength(1);
    expect(existsLines[0][1]).toBe('exists "A"');
  });
});
