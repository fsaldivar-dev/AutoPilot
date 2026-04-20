// Frontend wrapper around the Rust executor commands.

import { invoke } from "@tauri-apps/api/core";
import type { Frame } from "../domain/types";

export async function spawn(platform: "ios" | "android"): Promise<string> {
  return invoke<string>("executor_spawn", { platform });
}

export async function send(
  sessionId: string,
  line: string,
  timeoutMs?: number
): Promise<Frame> {
  return invoke<Frame>("executor_send", { sessionId, line, timeoutMs });
}

export async function kill(sessionId: string): Promise<void> {
  await invoke("executor_kill", { sessionId });
}

export async function status(sessionId: string): Promise<unknown> {
  return invoke("executor_status", { sessionId });
}

// Errors that mean the sidecar died and we should respawn.
function isDeadSessionError(msg: string): boolean {
  return /session dead|unknown session|session closed|EOF from CLI|session writer closed/i.test(msg);
}

// send() that respawns the sidecar transparently if it died.
// Returns both the frame and the (possibly new) sessionId so the caller
// can update the store.
export async function sendWithRecover(
  platform: "ios" | "android",
  sessionId: string | undefined,
  line: string,
  timeoutMs?: number
): Promise<{ frame: Frame; sessionId: string }> {
  let sid = sessionId;
  if (!sid) {
    sid = await spawn(platform);
  }
  try {
    const frame = await send(sid, line, timeoutMs);
    return { frame, sessionId: sid };
  } catch (e) {
    const msg = (e as Error).message ?? String(e);
    if (!isDeadSessionError(msg)) throw e;
    // Respawn + single retry.
    sid = await spawn(platform);
    const frame = await send(sid, line, timeoutMs);
    return { frame, sessionId: sid };
  }
}
