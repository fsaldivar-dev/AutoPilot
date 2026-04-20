import { useState } from "react";
import { selectCurrentFlow, selectCurrentProject, useStore } from "../state/store";
import * as executor from "../services/executor";
import { runFlow } from "../services/flowRunner";

interface Props {
  platform: "ios" | "android" | "both";
}

export function RunFlowButton({ platform }: Props) {
  const flow = useStore(selectCurrentFlow);
  const project = useStore(selectCurrentProject);
  const running = useStore((s) => s.running);
  const sessionId = useStore((s) => s.sessionId);
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

    // Ensure session.
    let sess = sessionId;
    if (!sess) {
      try {
        sess = await executor.spawn(runtime);
        setSession(sess, runtime);
      } catch (e) {
        showToast("err", `Sin CLI: ${(e as Error).message ?? e}`);
        return;
      }
    }

    setRunning(true);
    setAborting(false);

    const result = await runFlow(sess, runtime, flow, project.env, {
      onBlockStart: (id) => {
        updateBlock(flow.id, id, { meta: { status: "running", ranAt: Date.now() } });
      },
      onBlockEnd: (id, ok, ms, err) => {
        updateBlock(flow.id, id, {
          meta: {
            status: ok ? "ok" : "err",
            ms,
            error: err,
            ranAt: Date.now(),
          },
        });
      },
      shouldAbortOnError: () => aborting,
      onSessionChange: (newSid) => setSession(newSid, runtime),
      onUIMutation: () => bumpRefreshTick(),
    });

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
