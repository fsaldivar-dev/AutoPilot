import { describe, expect, it, vi } from "vitest";
import { RunRecorder } from "./runRecorder";
import type { RunRecord } from "../domain/types";

function makeDeps(overrides: Partial<Parameters<typeof mkRecorder>[0]> = {}) {
  const saved: RunRecord[] = [];
  const shots: Array<{ id: string; runId: string; dataUrl: string }> = [];
  let idc = 0;
  const deps = {
    capture: vi.fn(async () => "data:image/png;base64,AAAA"),
    saveScreenshot: vi.fn(async (id: string, runId: string, _at: number, dataUrl: string) => {
      shots.push({ id, runId, dataUrl });
    }),
    saveRun: vi.fn(async (run: RunRecord) => {
      saved.push(run);
    }),
    now: () => 1000,
    genId: (prefix: string) => `${prefix}-${idc++}`,
    ...overrides,
  };
  return { deps, saved, shots };
}

function mkRecorder(deps: ConstructorParameters<typeof RunRecorder>[1]) {
  return new RunRecorder("f1", deps);
}

describe("RunRecorder", () => {
  it("captura screenshot y guarda screenshotId en el evento", async () => {
    const { deps, shots } = makeDeps();
    const rec = mkRecorder(deps);
    await rec.recordStep("b1", true, 42, undefined, true);
    const run = await rec.finish("passed");

    expect(deps.capture).toHaveBeenCalledTimes(1);
    expect(shots).toHaveLength(1);
    expect(run.events).toHaveLength(1);
    const ev = run.events[0];
    expect(ev.blockId).toBe("b1");
    expect(ev.ok).toBe(true);
    expect(ev.ms).toBe(42);
    expect(ev.screenshotId).toBe(shots[0].id);
    expect(shots[0].runId).toBe(run.id);
  });

  it("no captura para bloques logic (shouldCapture=false)", async () => {
    const { deps } = makeDeps();
    const rec = mkRecorder(deps);
    await rec.recordStep("if1", true, undefined, undefined, false);
    const run = await rec.finish("passed");

    expect(deps.capture).not.toHaveBeenCalled();
    expect(run.events[0].screenshotId).toBeUndefined();
  });

  it("best-effort: si la captura falla, el paso queda sin screenshot y el run continúa", async () => {
    const { deps } = makeDeps({
      capture: vi.fn(async () => {
        throw new Error("device gone");
      }),
    });
    const rec = mkRecorder(deps);
    await rec.recordStep("b1", true, 10, undefined, true);
    await rec.recordStep("b2", false, 5, "boom", true);
    const run = await rec.finish("failed");

    expect(run.events).toHaveLength(2);
    expect(run.events[0].screenshotId).toBeUndefined();
    expect(run.events[1].screenshotId).toBeUndefined();
    expect(run.events[1].err).toBe("boom");
    expect(run.status).toBe("failed");
  });

  it("captura null (sin imagen) no genera screenshotId ni llama saveScreenshot", async () => {
    const { deps, shots } = makeDeps({ capture: vi.fn(async () => null) });
    const rec = mkRecorder(deps);
    await rec.recordStep("b1", true, 1, undefined, true);
    const run = await rec.finish("passed");

    expect(deps.saveScreenshot).not.toHaveBeenCalled();
    expect(shots).toHaveLength(0);
    expect(run.events[0].screenshotId).toBeUndefined();
  });

  it("finish persiste el run con flowId, timestamps y status", async () => {
    const { deps, saved } = makeDeps();
    const rec = mkRecorder(deps);
    await rec.recordStep("b1", true, 1, undefined, false);
    const run = await rec.finish("cancelled");

    expect(saved).toHaveLength(1);
    expect(saved[0].id).toBe(run.id);
    expect(saved[0].flowId).toBe("f1");
    expect(saved[0].startedAt).toBe(1000);
    expect(saved[0].endedAt).toBe(1000);
    expect(saved[0].status).toBe("cancelled");
  });

  it("un fallo en saveRun no propaga (persistencia best-effort)", async () => {
    const { deps } = makeDeps({
      saveRun: vi.fn(async () => {
        throw new Error("db locked");
      }),
    });
    const rec = mkRecorder(deps);
    await rec.recordStep("b1", true, 1, undefined, false);
    await expect(rec.finish("passed")).resolves.toBeDefined();
  });
});
