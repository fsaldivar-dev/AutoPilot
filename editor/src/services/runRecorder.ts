// Graba un "run record" de la ejecución de un flow: por cada bloque que se
// ejecuta, captura {stepIndex, comando, ok/fail, ms, timestamp, screenshotId}
// y lo persiste (run_records + screenshots) para el replay paso a paso (#163).
//
// El screenshot se toma best-effort REUSANDO el mismo `screenshot_only` que
// alimenta el mirror del DevicePreview — no duplica captura. Si la captura
// falla, el evento se guarda sin screenshotId y el run continúa: nunca rompe
// al runner.

import type { RunEvent, RunRecord, RunStatus } from "../domain/types";

// Captura un screenshot del estado actual del dispositivo como data-URI, o
// null si falla. Se inyecta para poder testear sin Tauri.
export type CaptureFn = () => Promise<string | null>;

// Persiste el PNG de un paso bajo `screenshotId`, ligado al run. Se inyecta.
export type SaveScreenshotFn = (
  screenshotId: string,
  runId: string,
  capturedAt: number,
  dataUrl: string
) => Promise<void>;

// Persiste el run record completo. Se inyecta.
export type SaveRunFn = (run: RunRecord) => Promise<void>;

export interface RecorderDeps {
  capture: CaptureFn;
  saveScreenshot: SaveScreenshotFn;
  saveRun: SaveRunFn;
  now?: () => number;
  genId?: (prefix: string) => string;
}

let seq = 0;
function defaultId(prefix: string): string {
  seq += 1;
  return `${prefix}-${Date.now().toString(36)}-${seq.toString(36)}`;
}

// Acumula eventos durante un run y persiste el record al final.
export class RunRecorder {
  private events: RunEvent[] = [];
  private startedAt: number;
  private now: () => number;
  private genId: (prefix: string) => string;
  readonly runId: string;

  constructor(
    readonly flowId: string,
    private deps: RecorderDeps
  ) {
    this.now = deps.now ?? (() => Date.now());
    this.genId = deps.genId ?? defaultId;
    this.startedAt = this.now();
    this.runId = this.genId("run");
  }

  // Registra el fin de un bloque ejecutado y captura su screenshot
  // best-effort. `shouldCapture` es false para bloques logic sin efecto
  // visual (if/repeat/try wrappers) — solo capturamos en comandos reales.
  async recordStep(
    blockId: string,
    ok: boolean,
    ms: number | undefined,
    err: string | undefined,
    shouldCapture: boolean
  ): Promise<void> {
    const timestamp = this.now();
    let screenshotId: string | undefined;
    if (shouldCapture) {
      try {
        const dataUrl = await this.deps.capture();
        if (dataUrl) {
          screenshotId = this.genId("shot");
          await this.deps.saveScreenshot(
            screenshotId,
            this.runId,
            timestamp,
            dataUrl
          );
        }
      } catch {
        // Captura best-effort: si falla, el paso queda sin screenshot.
        screenshotId = undefined;
      }
    }
    this.events.push({
      blockId,
      phase: "end",
      ok,
      ms,
      err,
      screenshotId,
      timestamp,
    });
  }

  // Persiste el run record final. `status` refleja el resultado global.
  async finish(status: RunStatus): Promise<RunRecord> {
    const run: RunRecord = {
      id: this.runId,
      flowId: this.flowId,
      startedAt: this.startedAt,
      endedAt: this.now(),
      status,
      events: this.events,
    };
    try {
      await this.deps.saveRun(run);
    } catch {
      // Persistencia best-effort — no rompe la UI del run.
    }
    return run;
  }

  // Número de pasos registrados hasta ahora (para tests/telemetría).
  get stepCount(): number {
    return this.events.length;
  }
}
