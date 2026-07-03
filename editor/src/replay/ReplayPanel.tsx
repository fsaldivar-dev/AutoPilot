// Vista de replay paso a paso (#163) — paridad con Maestro Studio.
//
// Lista los runs pasados del flow actual y, al seleccionar uno, permite
// navegar paso a paso viendo el screenshot capturado en ese punto + el
// comando ejecutado + estado (ok/fail) + duración. Reusa el marco visual del
// DevicePreview (.device-preview / .screen).

import { useCallback, useEffect, useMemo, useState } from "react";
import { selectCurrentFlow, useStore } from "../state/store";
import * as db from "../services/db";
import type { Block, RunEvent, RunRecord } from "../domain/types";

// blockId → texto del comando, aplanando slots anidados (if/repeat/try).
function buildCommandMap(blocks: Block[]): Map<string, string> {
  const map = new Map<string, string>();
  const walk = (bs: Block[]) => {
    for (const b of bs) {
      if (b.command) map.set(b.id, b.command);
      else if (b.kind === "logic") map.set(b.id, b.logicKind ?? "logic");
      if (b.slots) for (const slot of b.slots) walk(slot);
    }
  };
  walk(blocks);
  return map;
}

function fmtTime(ms: number): string {
  return new Date(ms).toLocaleString("es-MX", { hour12: false });
}

export function ReplayPanel() {
  const flow = useStore(selectCurrentFlow);
  const showToast = useStore((s) => s.showToast);
  const [runs, setRuns] = useState<RunRecord[]>([]);
  const [selectedRunId, setSelectedRunId] = useState<string | null>(null);
  const [stepIdx, setStepIdx] = useState(0);
  const [shot, setShot] = useState<string | null>(null);
  const [loadingShot, setLoadingShot] = useState(false);

  const flowId = flow?.id;
  const commandMap = useMemo(
    () => (flow ? buildCommandMap(flow.blocks) : new Map<string, string>()),
    [flow]
  );

  const loadRuns = useCallback(async () => {
    if (!flowId) return;
    try {
      const list = await db.listRuns(flowId, 20);
      setRuns(list);
    } catch {
      // Tauri no disponible (tests / preview web).
    }
  }, [flowId]);

  useEffect(() => {
    void loadRuns();
    setSelectedRunId(null);
    setStepIdx(0);
    setShot(null);
  }, [loadRuns]);

  const selectedRun = runs.find((r) => r.id === selectedRunId) ?? null;
  const steps: RunEvent[] = selectedRun?.events ?? [];
  const step = steps[stepIdx];

  // Carga perezosa del screenshot del paso actual.
  useEffect(() => {
    let cancelled = false;
    setShot(null);
    if (!step?.screenshotId) return;
    setLoadingShot(true);
    db.getScreenshot(step.screenshotId)
      .then((url) => {
        if (!cancelled) setShot(url);
      })
      .catch(() => {})
      .finally(() => {
        if (!cancelled) setLoadingShot(false);
      });
    return () => {
      cancelled = true;
    };
  }, [step?.screenshotId]);

  function openRun(runId: string) {
    setSelectedRunId(runId);
    setStepIdx(0);
  }

  async function onDelete(runId: string, e: React.MouseEvent) {
    e.stopPropagation();
    try {
      await db.deleteRun(runId);
      if (selectedRunId === runId) setSelectedRunId(null);
      await loadRuns();
    } catch {
      showToast("err", "No se pudo borrar el run");
    }
  }

  if (!flow) return null;

  return (
    <div className="replay" data-testid="replay-panel">
      <div
        className="section-title"
        style={{ display: "flex", justifyContent: "space-between" }}
      >
        <span>Replay · runs</span>
        <button className="btn btn-icon" onClick={() => void loadRuns()} title="Recargar runs">
          ↻
        </button>
      </div>

      {!selectedRun ? (
        runs.length === 0 ? (
          <div style={{ fontSize: 11, color: "var(--text-mute)" }}>
            Sin runs grabados. Ejecuta el flow para grabar uno.
          </div>
        ) : (
          <div className="replay-run-list">
            {runs.map((r) => (
              <div
                key={r.id}
                className="replay-run-row"
                data-testid={`run-${r.id}`}
                onClick={() => openRun(r.id)}
              >
                <span
                  className={`replay-badge ${r.status}`}
                  title={r.status}
                >
                  {r.status === "passed"
                    ? "✓"
                    : r.status === "failed"
                      ? "✗"
                      : "•"}
                </span>
                <span style={{ flex: 1, fontSize: 11 }}>{fmtTime(r.startedAt)}</span>
                <span style={{ fontSize: 10.5, color: "var(--text-mute)" }}>
                  {r.events.length} pasos
                </span>
                <button
                  className="btn btn-icon"
                  title="Borrar run"
                  onClick={(e) => void onDelete(r.id, e)}
                >
                  ✕
                </button>
              </div>
            ))}
          </div>
        )
      ) : (
        <div className="replay-viewer">
          <button
            className="btn btn-link"
            data-testid="replay-back"
            onClick={() => setSelectedRunId(null)}
            style={{ fontSize: 11, marginBottom: 6 }}
          >
            ← Runs
          </button>

          <div className="device-preview">
            <div className="screen">
              {shot ? (
                <img
                  src={shot}
                  alt="step"
                  style={{ width: "100%", height: "100%", objectFit: "cover" }}
                />
              ) : (
                <div
                  style={{
                    color: "var(--text-mute)",
                    fontSize: 11,
                    textAlign: "center",
                    paddingTop: "50%",
                  }}
                >
                  {loadingShot
                    ? "Cargando..."
                    : step?.screenshotId
                      ? "Sin imagen"
                      : "Paso sin captura"}
                </div>
              )}
            </div>
          </div>

          <div className="replay-nav" data-testid="replay-nav">
            <button
              className="btn"
              data-testid="replay-prev"
              disabled={stepIdx <= 0}
              onClick={() => setStepIdx((i) => Math.max(0, i - 1))}
            >
              ‹
            </button>
            <span style={{ flex: 1, textAlign: "center", fontSize: 11 }}>
              Paso {stepIdx + 1} / {steps.length}
            </span>
            <button
              className="btn"
              data-testid="replay-next"
              disabled={stepIdx >= steps.length - 1}
              onClick={() => setStepIdx((i) => Math.min(steps.length - 1, i + 1))}
            >
              ›
            </button>
          </div>

          {step && (
            <div className="replay-step-info">
              <div className="replay-cmd" data-testid="replay-cmd">
                {commandMap.get(step.blockId) ?? step.blockId}
              </div>
              <div style={{ display: "flex", gap: 8, alignItems: "center", marginTop: 4 }}>
                <span
                  style={{
                    color: step.ok ? "var(--mint)" : "var(--coral)",
                    fontSize: 11,
                    fontWeight: 600,
                  }}
                >
                  {step.ok ? "✓ ok" : "✗ fail"}
                </span>
                <span style={{ fontSize: 11, color: "var(--text-mute)" }}>
                  {step.ms ?? 0}ms
                </span>
                <span style={{ fontSize: 10.5, color: "var(--text-mute)" }}>
                  {new Date(step.timestamp).toLocaleTimeString("es-MX", { hour12: false })}
                </span>
              </div>
              {step.err && (
                <div style={{ fontSize: 10.5, color: "var(--coral)", marginTop: 4 }}>
                  {step.err}
                </div>
              )}
            </div>
          )}
        </div>
      )}
    </div>
  );
}
