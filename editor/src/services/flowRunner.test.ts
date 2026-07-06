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
    onBlockStart: (id: string) => { started.push(id); },
    onBlockEnd: (id: string, ok: boolean) => { ended.push({ id, ok }); },
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

// Regresión de las "mentiras en verde" del editor que el QA cazó (#170/#171).
describe("flowRunner honestidad (#170/#171)", () => {
  it("un paso fallido ABORTA el flow — no continúa en verde", async () => {
    sendMock.mockImplementation(async (sid, line) => {
      if (line === 'tap "boom"') return { frame: errFrame("element not found"), sessionId: sid };
      return { frame: okFrame(), sessionId: sid };
    });
    const flow = makeFlow([cmd("a", 'tap "boom"'), cmd("b", 'tap "no debe correr"')]);
    const cb = mkCb();
    const r = await runFlow("s1", "ios", flow, [], cb);
    expect(r.ok).toBe(false);              // run = failed, no passed
    expect(r.errored).toBe("a");
    expect(cb.ended.find(e => e.id === "a")?.ok).toBe(false);
    // el paso b NUNCA se ejecutó (antes el flow seguía y terminaba "passed")
    expect(sendMock.mock.calls.some(c => c[1] === 'tap "no debe correr"')).toBe(false);
  });

  it("session death mid-flow (respawn) marca el paso FAILED aunque el retry diga ok", async () => {
    // sendWithRecover respawnea y devuelve un sessionId DISTINTO con frame.ok=true:
    // es el "tap fantasma" — el retry corrió sobre otra pantalla.
    sendMock.mockImplementation(async (_sid, _line) => ({ frame: okFrame(), sessionId: "s-RESPAWNED" }));
    const flow = makeFlow([cmd("a", 'tap "No Existe"')]);
    const cb = mkCb();
    const r = await runFlow("s1", "ios", flow, [], cb);
    expect(cb.ended.find(e => e.id === "a")?.ok).toBe(false); // no miente en verde
    expect(r.ok).toBe(false);
  });

  it("shouldStop del usuario aborta aunque los pasos vayan en verde", async () => {
    sendMock.mockImplementation(async (sid) => ({ frame: okFrame(), sessionId: sid ?? "s1" }));
    let stop = false;
    const started: string[] = [];
    const cb = {
      started,
      onBlockStart: (id: string) => { started.push(id); stop = true; }, // pedir stop tras el 1er bloque
      onBlockEnd: () => {},
      shouldAbortOnError: () => true,
      shouldStop: () => stop,
    };
    const flow = makeFlow([cmd("a", 'tap "A"'), cmd("b", 'tap "B"'), cmd("c", 'tap "C"')]);
    const r = await runFlow("s1", "ios", flow, [], cb as any);
    expect(r.ok).toBe(false);
    // se corrió 'a', se pidió stop, 'b'/'c' no corren
    expect(sendMock.mock.calls.filter(c => String(c[1]).startsWith("tap ")).length).toBe(1);
  });
});

describe("flowRunner replay capture (#172)", () => {
  it("espera la promise de onBlockEnd antes de mandar el siguiente comando", async () => {
    // Simula la captura del RunRecorder: onBlockEnd devuelve una promise que
    // resuelve más tarde. El runner DEBE esperarla — si no, el screenshot del
    // paso N se encola en paralelo con el comando N+1 (FIFO desalineado,
    // tabla screenshots vacía).
    const order: string[] = [];
    sendMock.mockImplementation(async (sid, line) => {
      order.push(`send:${line}`);
      return { frame: okFrame(), sessionId: sid ?? "s1" };
    });
    const flow = makeFlow([cmd("a", 'tap "A"'), cmd("b", 'tap "B"')]);
    await runFlow("s1", "ios", flow, [], {
      onBlockStart: () => {},
      onBlockEnd: async (id) => {
        order.push(`capture-start:${id}`);
        await new Promise((r) => setTimeout(r, 10));
        order.push(`capture-end:${id}`);
      },
      shouldAbortOnError: () => true,
    });
    expect(order).toEqual([
      'send:tap "A"',
      "capture-start:a",
      "capture-end:a",
      'send:tap "B"',
      "capture-start:b",
      "capture-end:b",
    ]);
  });
});

// #195 — variables de script: $nombre = valor + sustitución local.
describe("variables de script (#195)", () => {
  it("el binding no viaja al CLI y camera feed $ocr va sustituido", async () => {
    sendMock.mockImplementation(async (sid, _line) => ({
      frame: okFrame(), sessionId: sid ?? "s1",
    }));
    const flow = makeFlow([
      cmd("b1", "$ocr = images/ocr-test.png"),
      cmd("b2", "camera feed $ocr"),
    ]);
    const cb = mkCb();
    const r = await runFlow("s1", "ios", flow, [], cb);
    expect(r.ok).toBe(true);
    expect(r.ran).toBe(2);
    expect(cb.ended).toEqual([{ id: "b1", ok: true }, { id: "b2", ok: true }]);
    expect(sendMock).toHaveBeenCalledTimes(1);
    expect(sendMock).toHaveBeenCalledWith("s1", "camera feed images/ocr-test.png");
  });

  it("el binding shadowea el env del proyecto sin mutarlo; la última asignación gana", async () => {
    sendMock.mockImplementation(async (sid, _line) => ({
      frame: okFrame(), sessionId: sid ?? "s1",
    }));
    const projectEnv = [
      { projectId: "p1", scope: "asset", key: "img", value: "images/proyecto.png", secret: false },
    ];
    const flow = makeFlow([
      cmd("b1", "inject $img"),
      cmd("b2", "$img = images/local.png"),
      cmd("b3", "inject $img"),
      cmd("b4", "$img = images/otra.png"),
      cmd("b5", "inject $img"),
    ]);
    await runFlow("s1", "ios", flow, projectEnv, mkCb());
    const lines = sendMock.mock.calls.map((c) => c[1]);
    expect(lines).toEqual([
      "inject images/proyecto.png",
      "inject images/local.png",
      "inject images/otra.png",
    ]);
    expect(projectEnv).toHaveLength(1);
  });
});
