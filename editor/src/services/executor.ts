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
