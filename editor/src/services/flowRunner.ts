// Runs a sequence of blocks against an executor session, substituting
// `$var` references against the project's env vars before sending.

import type { EnvVar, Flow } from "../domain/types";
import * as executor from "./executor";

export interface RunnerCallbacks {
  onBlockStart: (blockId: string) => void;
  onBlockEnd: (
    blockId: string,
    ok: boolean,
    ms: number | undefined,
    err?: string
  ) => void;
  shouldAbortOnError: () => boolean;
}

export function substituteVars(command: string, vars: EnvVar[]): string {
  if (!command || vars.length === 0) return command;
  return command.replace(/\$([A-Za-z_][A-Za-z0-9_.]*)/g, (whole, key) => {
    const match = vars.find((v) => v.key === key);
    return match ? match.value : whole;
  });
}

export async function runFlow(
  sessionId: string,
  flow: Flow,
  envVars: EnvVar[],
  cb: RunnerCallbacks
): Promise<{ ok: boolean; ran: number; errored?: string }> {
  let ran = 0;
  for (const block of flow.blocks) {
    if (block.kind !== "command" && block.kind !== "component") continue;
    if (!block.command) continue;

    const line = substituteVars(block.command, envVars);
    cb.onBlockStart(block.id);

    try {
      const timeoutMs =
        typeof block.args?.timeout === "number"
          ? (block.args.timeout as number)
          : undefined;
      const frame = await executor.send(sessionId, line, timeoutMs);
      ran++;
      cb.onBlockEnd(block.id, frame.ok, frame.ms, frame.err ?? undefined);
      if (!frame.ok && cb.shouldAbortOnError()) {
        return { ok: false, ran, errored: block.id };
      }
    } catch (e) {
      cb.onBlockEnd(block.id, false, undefined, (e as Error).message ?? String(e));
      if (cb.shouldAbortOnError()) {
        return { ok: false, ran, errored: block.id };
      }
    }
  }
  return { ok: true, ran };
}
