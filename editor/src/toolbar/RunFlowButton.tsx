import { useState } from "react";
import { invoke } from "@tauri-apps/api/core";
import { selectCurrentFlow, selectCurrentProject, useStore } from "../state/store";
import * as executor from "../services/executor";
import { runFlow } from "../services/flowRunner";
import { RunRecorder } from "../services/runRecorder";
import * as db from "../services/db";
import type { Block, RunStatus } from "../domain/types";

// Bloques cuyo screenshot capturamos en el replay: comandos y componentes
// reales. Los wrappers logic (if/repeat/try) no tienen estado visual propio.
function isCapturableBlock(flow: { blocks: Block[] }, id: string): boolean {
  const walk = (blocks: Block[]): boolean => {
    for (const b of blocks) {
      if (b.id === id) return b.kind === "command" || b.kind === "component";
      if (b.slots) for (const slot of b.slots) if (walk(slot)) return true;
    }
    return false;
  };
  return walk(flow.blocks);
}

interface Props {
  platform: "ios" | "android" | "both";
}

export function RunFlowButton({ platform }: Props) {
  const flow = useStore(selectCurrentFlow);
  const project = useStore(selectCurrentProject);
  const running = useStore((s) => s.running);
  const setSession = useStore((s) => s.setSession);
  const setRunning = useStore((s) => s.setRunning);
  const updateBlock = useStore((s) => s.updateBlock);
  const showToast = useStore((s) => s.showToast);
  const bumpRefreshTick = useStore((s) => s.bumpRefreshTick);
  const [aborting, setAborting] = useState(false);

  const disabled = !flow || flow.blocks.length === 0;
  const runtime = platform === "android" ? "android" : "ios";

  async function onRun() {
    if (!flow || !project) return;
    if (running) {
      // User clicked while running — signal abort via state flag.
      setAborting(true);
      return;
    }

    // Reset block statuses.
    for (const b of flow.blocks) {
      updateBlock(flow.id, b.id, { meta: { status: "idle" } });
    }

    // Sesión de la plataforma correcta (#198): si la sesión viva es de otra
    // plataforma, ensureSessionForPlatform la mata y respawnea la correcta —
    // antes reusaba la sesión iOS al correr Android y viceversa.
    let sess: string;
    try {
      sess = await executor.ensureSessionForPlatform(runtime);
    } catch (e) {
      showToast("err", `Sin CLI: ${(e as Error).message ?? e}`);
      return;
    }

    setRunning(true);
    setAborting(false);

    // Grabador del run (#163): captura screenshot+comando+estado por paso y
    // persiste run_records + screenshots para el replay. La captura reusa el
    // mismo `screenshot_only` que alimenta el mirror del DevicePreview.
    const recorder = new RunRecorder(flow.id, {
      capture: async () => {
        try {
          const cur = useStore.getState().sessionId ?? sess ?? null;
          return await invoke<string>("screenshot_only", {
            platform: runtime,
            sessionId: cur,
          });
        } catch {
          return null;
        }
      },
      saveScreenshot: db.saveScreenshot,
      saveRun: db.saveRun,
    });
    const result = await runFlow(sess, runtime, flow, project.env, {
      onBlockStart: (id) => {
        updateBlock(flow.id, id, { meta: { status: "running", ranAt: Date.now() } });
      },
      // El runner ESPERA esta promise antes de mandar el siguiente comando
      // (#172): así el `screenshot` del recorder entra a la cola FIFO del
      // sidecar justo después de la respuesta del paso — antes se encolaba
      // en paralelo con el comando N+1 y la captura expiraba/llegaba
      // huérfana (tabla screenshots vacía).
      onBlockEnd: (id, ok, ms, err) => {
        updateBlock(flow.id, id, {
          meta: {
            status: ok ? "ok" : "err",
            ms,
            error: err,
            ranAt: Date.now(),
          },
        });
        return recorder.recordStep(id, ok, ms, err, isCapturableBlock(flow, id));
      },
      // #170: un paso fallido DEBE abortar el flow (honestidad tipo script).
      // Antes `() => aborting` dejaba continuar tras un fallo → el run
      // terminaba "passed" con pasos rotos.
      shouldAbortOnError: () => true,
      // El Stop del usuario aborta en cualquier punto, no solo tras un fallo.
      shouldStop: () => aborting,
      onSessionChange: (newSid) => setSession(newSid, runtime),
      onUIMutation: () => bumpRefreshTick(),
    });

    // runFlow ya esperó cada recordStep (onBlockEnd awaited) — solo queda
    // persistir el record final.
    const status: RunStatus = aborting
      ? "cancelled"
      : result.ok
        ? "passed"
        : "failed";
    await recorder.finish(status);

    setRunning(false);
    if (result.ok) {
      showToast("ok", `✓ Flow completado · ${result.ran} bloques`);
    } else {
      showToast("err", `✗ Flow fallo en bloque ${result.errored}`);
    }
  }

  return (
    <button
      className={running ? "btn btn-danger" : "btn btn-primary"}
      onClick={() => void onRun()}
      disabled={disabled}
      data-testid="run-flow-btn"
      title={running ? "Abortar" : "Ejecutar todo el flow (⌘↵)"}
      style={{
        display: "inline-flex",
        alignItems: "center",
        gap: 6,
        fontWeight: 600,
        fontSize: 12,
      }}
    >
      {running ? (
        <>
          <span>■</span> Abortar
        </>
      ) : (
        <>
          <span style={{ fontSize: 10 }}>▶</span> Run flow
        </>
      )}
    </button>
  );
}
