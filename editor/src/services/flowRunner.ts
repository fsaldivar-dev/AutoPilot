// Runs a sequence of blocks against an executor session, substituting
// `$var` references against the project's env vars before sending.
// Soporta control flow: if/else, repeat times/while/until, try/catch, assert.
// Los predicados se evalúan enviando comandos sueltos al sidecar CLI
// (`exists`, `visible`, `hasText`, `platform`, `orientation`) y leyendo
// frame.ok o frame.out como resultado booleano.

import type { Block, EnvVar, Flow, Predicate } from "../domain/types";
import * as executor from "./executor";

export interface RunnerCallbacks {
  onBlockStart: (blockId: string) => void;
  onBlockEnd: (
    blockId: string,
    ok: boolean,
    ms: number | undefined,
    err?: string
  ) => void;
  // true → un paso fallido aborta el flow. Default esperado: siempre true
  // (honestidad tipo script). El estado del run se marca "failed" via result.ok.
  shouldAbortOnError: () => boolean;
  // true → el usuario pidió Stop; aborta en el próximo límite de bloque
  // aunque los pasos vayan en verde (#170). Marca el run como "cancelled".
  shouldStop?: () => boolean;
  // Fired when the sidecar was respawned mid-run. Caller should persist
  // the new sessionId in the store.
  onSessionChange?: (newSessionId: string) => void;
  // Disparado después de cada comando que puede haber mutado la UI
  // (tap, type, swipe, scroll, launch, etc.). El caller típicamente
  // triggerea un screenshot/tree refresh en el inspector para mantener
  // la vista fluida. Safe para fire-and-forget — el runner no espera.
  onUIMutation?: () => void;
}

// Comandos que típicamente mutan la UI y justifican un refresh reactivo.
// Queries/predicados (exists/visible/tree/etc) NO están en la lista.
const UI_MUTATORS = new Set([
  "tap", "doubleTap", "longPress", "tapAt",
  "type", "clear", "eraseText", "pressKey", "hideKeyboard",
  "swipe", "scroll", "scrollTo", "scrollUntilVisible", "drag",
  "launch", "terminate", "install", "uninstall", "clearState",
  "rotate", "setAppearance", "lockDevice", "unlockDevice",
  "openurl", "paste", "media",
  "waitFor", "waitUntilGone",
]);

function isUIMutator(command: string): boolean {
  const first = command.trim().split(/\s+/)[0]?.split("[")[0] ?? "";
  return UI_MUTATORS.has(first);
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
  platform: "ios" | "android",
  flow: Flow,
  envVars: EnvVar[],
  cb: RunnerCallbacks
): Promise<{ ok: boolean; ran: number; errored?: string; sessionId: string }> {
  const state: RunState = { sid: sessionId, ran: 0, errored: undefined };
  try {
    await runBlocksSeq(flow.blocks, platform, envVars, state, cb);
    return { ok: !state.errored, ran: state.ran, errored: state.errored, sessionId: state.sid };
  } catch (e) {
    // AbortedError → normal early-exit, no-op.
    return { ok: false, ran: state.ran, errored: state.errored, sessionId: state.sid };
  }
}

// Run a single block (ignoring logic wrappers). Respawns the sidecar if
// the previous session died.
export async function runBlock(
  sessionId: string | undefined,
  platform: "ios" | "android",
  block: Block,
  envVars: EnvVar[],
  cb: {
    onStart?: () => void;
    onEnd: (ok: boolean, ms: number | undefined, err?: string) => void;
    onSessionChange?: (newSessionId: string) => void;
    onUIMutation?: () => void;
  }
): Promise<string | undefined> {
  if (block.kind === "logic" || !block.command) {
    cb.onEnd(false, undefined, "Bloque no ejecutable");
    return sessionId;
  }
  const line = substituteVars(block.command, envVars);
  cb.onStart?.();
  try {
    const timeoutMs =
      typeof block.args?.timeout === "number"
        ? (block.args.timeout as number)
        : undefined;
    const { frame, sessionId: newSid } = await executor.sendWithRecover(
      platform,
      sessionId,
      line,
      timeoutMs
    );
    if (newSid !== sessionId) cb.onSessionChange?.(newSid);
    cb.onEnd(frame.ok, frame.ms, frame.err ?? undefined);
    if (frame.ok && isUIMutator(block.command)) {
      cb.onUIMutation?.();
    }
    return newSid;
  } catch (e) {
    cb.onEnd(false, undefined, (e as Error).message ?? String(e));
    return sessionId;
  }
}

// ──────────────────────────────────────────────────────────────────────────────
// Recursive runner (internal)

interface RunState {
  sid: string;
  ran: number;
  errored?: string;
}

class AbortedError extends Error {
  constructor() { super("aborted"); }
}

async function runBlocksSeq(
  blocks: Block[],
  platform: "ios" | "android",
  envVars: EnvVar[],
  state: RunState,
  cb: RunnerCallbacks,
): Promise<void> {
  for (const block of blocks) {
    // #170: el Stop del usuario aborta en cualquier punto (antes solo se
    // chequeaba tras un fallo, así que un flow en verde no se podía parar).
    if (cb.shouldStop?.()) throw new AbortedError();
    if (block.kind === "logic") {
      await runLogicBlock(block, platform, envVars, state, cb);
    } else if (block.kind === "command" || block.kind === "component") {
      await runCommandBlock(block, platform, envVars, state, cb);
    }
  }
}

async function runCommandBlock(
  block: Block,
  platform: "ios" | "android",
  envVars: EnvVar[],
  state: RunState,
  cb: RunnerCallbacks,
): Promise<void> {
  if (!block.command) return;
  const line = substituteVars(block.command, envVars);
  cb.onBlockStart(block.id);
  try {
    const timeoutMs =
      typeof block.args?.timeout === "number"
        ? (block.args.timeout as number)
        : undefined;
    const { frame, sessionId: newSid } = await executor.sendWithRecover(
      platform, state.sid, line, timeoutMs,
    );
    // #170/#171: si la sesión murió y hubo que respawnearla A MITAD del flow,
    // la app se relanzó desde cero — el resultado de este paso NO es confiable
    // (el retry corrió sobre otra pantalla). Antes ese retry podía reportar
    // frame.ok=true "tapeando" un elemento de la pantalla equivocada. Lo
    // marcamos como fallo honesto en vez de mentir en verde.
    const sessionDied = newSid !== state.sid;
    if (sessionDied) {
      state.sid = newSid;
      cb.onSessionChange?.(newSid);
    }
    state.ran++;
    const stepOk = frame.ok && !sessionDied;
    const stepErr = sessionDied
      ? (frame.err ?? "la sesión murió durante el paso (app relanzada) — resultado no confiable")
      : (frame.err ?? undefined);
    cb.onBlockEnd(block.id, stepOk, frame.ms, stepErr);
    // Refresh reactivo: si el comando probable mutó la UI, disparamos un
    // refresh del inspector después de un pequeño delay (para dejar que las
    // animaciones terminen). Fire-and-forget.
    if (stepOk && isUIMutator(block.command)) {
      cb.onUIMutation?.();
    }
    if (!stepOk && cb.shouldAbortOnError()) {
      state.errored = block.id;
      throw new AbortedError();
    }
  } catch (e) {
    if (e instanceof AbortedError) throw e;
    cb.onBlockEnd(block.id, false, undefined, (e as Error).message ?? String(e));
    if (cb.shouldAbortOnError()) {
      state.errored = block.id;
      throw new AbortedError();
    }
  }
}

async function runLogicBlock(
  block: Block,
  platform: "ios" | "android",
  envVars: EnvVar[],
  state: RunState,
  cb: RunnerCallbacks,
): Promise<void> {
  switch (block.logicKind) {
    case "if": {
      if (!block.predicate) return;
      cb.onBlockStart(block.id);
      const ok = await evalPredicate(block.predicate, platform, envVars, state, cb);
      const branch = ok ? (block.slots?.[0] ?? []) : (block.slots?.[1] ?? []);
      try {
        await runBlocksSeq(branch, platform, envVars, state, cb);
        cb.onBlockEnd(block.id, true, undefined);
      } catch (e) {
        cb.onBlockEnd(block.id, false, undefined, "branch failed");
        throw e;
      }
      return;
    }
    case "repeat": {
      if (!block.repeat) return;
      const body = block.slots?.[0] ?? [];
      cb.onBlockStart(block.id);
      try {
        switch (block.repeat.mode) {
          case "times": {
            const n = Math.max(0, block.repeat.n);
            for (let i = 0; i < n; i++) {
              await runBlocksSeq(body, platform, envVars, state, cb);
            }
            break;
          }
          case "while": {
            let guard = 0;
            while (await evalPredicate(block.repeat.pred, platform, envVars, state, cb)) {
              await runBlocksSeq(body, platform, envVars, state, cb);
              if (++guard > 10_000) break;
            }
            break;
          }
          case "until": {
            let guard = 0;
            while (!(await evalPredicate(block.repeat.pred, platform, envVars, state, cb))) {
              await runBlocksSeq(body, platform, envVars, state, cb);
              if (++guard > 10_000) break;
            }
            break;
          }
          case "foreach":
            // Paridad con Swift: no implementado aún — skip body con warning.
            console.warn("foreach no implementado aún; body skipped");
            break;
        }
        cb.onBlockEnd(block.id, true, undefined);
      } catch (e) {
        cb.onBlockEnd(block.id, false, undefined, "body failed");
        throw e;
      }
      return;
    }
    case "try": {
      const body = block.slots?.[0] ?? [];
      const catch_ = block.slots?.[1] ?? [];
      cb.onBlockStart(block.id);
      // Guardamos estado actual para restaurar en catch.
      const prevErrored = state.errored;
      try {
        // Temporariamente deshabilitamos abort-on-error para el body.
        await runBlocksSeqCatching(body, platform, envVars, state, cb);
        cb.onBlockEnd(block.id, true, undefined);
      } catch (e) {
        // El body falló → ejecutar catch, limpiar errored.
        state.errored = prevErrored;
        try {
          await runBlocksSeq(catch_, platform, envVars, state, cb);
          cb.onBlockEnd(block.id, true, undefined, "recovered via catch");
        } catch (e2) {
          cb.onBlockEnd(block.id, false, undefined, "catch also failed");
          throw e2;
        }
      }
      return;
    }
    case "assert": {
      if (!block.predicate) return;
      cb.onBlockStart(block.id);
      const ok = await evalPredicate(block.predicate, platform, envVars, state, cb);
      if (ok) {
        cb.onBlockEnd(block.id, true, undefined);
      } else {
        cb.onBlockEnd(block.id, false, undefined, "assertion failed");
        if (cb.shouldAbortOnError()) {
          state.errored = block.id;
          throw new AbortedError();
        }
      }
      return;
    }
    default:
      // logicKind legacy (else/catch/foreach suelto) — skip
      return;
  }
}

// runBlocksSeq variante que fuerza abort sobre error dentro del body (para try).
async function runBlocksSeqCatching(
  blocks: Block[],
  platform: "ios" | "android",
  envVars: EnvVar[],
  state: RunState,
  cb: RunnerCallbacks,
): Promise<void> {
  const overrideCb: RunnerCallbacks = { ...cb, shouldAbortOnError: () => true };
  await runBlocksSeq(blocks, platform, envVars, state, overrideCb);
}

// ──────────────────────────────────────────────────────────────────────────────
// evalPredicate — traduce Predicate a comandos CLI y evalúa boolean

export async function evalPredicate(
  pred: Predicate,
  platform: "ios" | "android",
  envVars: EnvVar[],
  state: RunState,
  cb: RunnerCallbacks,
): Promise<boolean> {
  switch (pred.kind) {
    case "not":
      return !(await evalPredicate(pred.inner, platform, envVars, state, cb));
    case "and": {
      const l = await evalPredicate(pred.left, platform, envVars, state, cb);
      if (!l) return false;
      return evalPredicate(pred.right, platform, envVars, state, cb);
    }
    case "or": {
      const l = await evalPredicate(pred.left, platform, envVars, state, cb);
      if (l) return true;
      return evalPredicate(pred.right, platform, envVars, state, cb);
    }
    case "call":
      return evalPredicateCall(pred.name, pred.args, platform, envVars, state, cb);
  }
}

function quote(s: string): string {
  if (s.startsWith("$")) return s;
  if (s.includes(" ")) return `"${s}"`;
  return `"${s}"`;
}

async function evalPredicateCall(
  name: string,
  args: string[],
  platform: "ios" | "android",
  envVars: EnvVar[],
  state: RunState,
  cb: RunnerCallbacks,
): Promise<boolean> {
  // Short-circuit cases that don't need CLI roundtrip.
  if (name === "platform" && args.length >= 2 && args[0] === "is") {
    return platform.toLowerCase() === args[1].toLowerCase();
  }

  let line: string | null = null;
  switch (name) {
    case "exists":
    case "visible":
      if (args.length >= 1) line = `${name} ${quote(args[0])}`;
      break;
    case "isVisible":
      if (args.length >= 1) line = `visible ${quote(args[0])}`;
      break;
    case "hasText":
      if (args.length >= 2) line = `hasText ${quote(args[0])} ${quote(args[1])}`;
      break;
    case "orientation":
      if (args.length >= 2 && args[0] === "is") line = "orientation";
      // Leer el orientation retornado por el CLI y comparar.
      if (line) {
        const frame = await sendLine(line, envVars, state, cb, platform);
        if (!frame) return false;
        const actual = (frame.out ?? "").trim().split(/\s+/)[0].toLowerCase();
        return actual === args[1].toLowerCase();
      }
      return false;
  }

  if (!line) return false;
  const frame = await sendLine(line, envVars, state, cb, platform);
  if (!frame) return false;

  // Convención CLI: predicados imprimen "YES (Nms)" o "NO (Nms)" en stdout,
  // y frame.ok es true si el comando ejecutó sin error. El valor booleano
  // se lee del prefijo del stdout.
  const out = (frame.out ?? "").trim();
  return out.startsWith("YES") || out === "true";
}

async function sendLine(
  line: string,
  envVars: EnvVar[],
  state: RunState,
  cb: RunnerCallbacks,
  platform: "ios" | "android",
): Promise<import("../domain/types").Frame | null> {
  const subst = substituteVars(line, envVars);
  try {
    const { frame, sessionId: newSid } = await executor.sendWithRecover(
      platform, state.sid, subst,
    );
    if (newSid !== state.sid) {
      state.sid = newSid;
      cb.onSessionChange?.(newSid);
    }
    return frame;
  } catch {
    return null;
  }
}
