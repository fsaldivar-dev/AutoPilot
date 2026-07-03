import { nanoid } from "nanoid";
import { useEffect, useMemo, useRef, useState } from "react";
import { suggest, tokenize } from "./autocomplete";
import { AutocompletePopover } from "./AutocompletePopover";
import { matchCommandLine } from "./catalog";
import { parsePredicate } from "./predicateText";
import { tokenizeLine } from "../domain/autoTokenize";
import { useStore, selectCurrentFlow, selectCurrentProject } from "../state/store";
import type {
  Block, Frame, Platform, RepeatMode, Suggestion,
} from "../domain/types";
import * as executor from "../services/executor";

const LOGIC_KEYWORDS = new Set(["if", "repeat", "try", "assert"]);

interface Props {
  platform: Platform;
}

export function CommandBar({ platform }: Props) {
  const [value, setValue] = useState("");
  const [cursor, setCursor] = useState(0);
  const [activeIndex, setActiveIndex] = useState(0);
  const [focused, setFocused] = useState(false);
  const [dismissed, setDismissed] = useState(false);
  // Feedback inline de validación (#180): comando desconocido → borde rojo +
  // mensaje, sin insertar bloque ni tocar el CLI.
  const [inputError, setInputError] = useState<string | null>(null);
  // true si el usuario navegó el popover con ↑/↓ (Enter entonces acepta la
  // selección aunque el token actual esté vacío).
  const [navigated, setNavigated] = useState(false);
  const inputRef = useRef<HTMLInputElement>(null);

  const flow = useStore(selectCurrentFlow);
  const project = useStore(selectCurrentProject);
  const elements = useStore((s) => s.elements);
  const recents = useStore((s) => s.recentBlocks);
  const sessionId = useStore((s) => s.sessionId);
  const setSession = useStore((s) => s.setSession);
  const appendBlock = useStore((s) => s.appendBlock);
  const updateBlock = useStore((s) => s.updateBlock);
  const pushRecent = useStore((s) => s.pushRecent);
  const setRunning = useStore((s) => s.setRunning);
  const showToast = useStore((s) => s.showToast);
  const bumpRefreshTick = useStore((s) => s.bumpRefreshTick);

  const components = project?.components ?? [];
  const envVars = project?.env ?? [];

  const runtimePlatform: "ios" | "android" = platform === "android" ? "android" : "ios";

  const suggestions: Suggestion[] = useMemo(() => {
    return suggest({
      input: value,
      cursor,
      platform: runtimePlatform,
      elements,
      components,
      envVars,
      recents,
    });
  }, [value, cursor, runtimePlatform, elements, components, envVars, recents]);

  useEffect(() => {
    setActiveIndex(0);
    setNavigated(false);
    // Any typing clears the dismissed flag so the popover can re-appear.
    if (value.length > 0) setDismissed(false);
  }, [value]);

  // Devuelve el nuevo value para que el caller (Enter) pueda detectar el caso
  // "la sugerencia ya está aplicada" y ejecutar en vez de re-aceptar.
  function pickSuggestion(s: Suggestion): string {
    // Replace current token with the insertText.
    const prefix = value.slice(0, cursor);
    const suffix = value.slice(cursor);
    const tokenStart = Math.max(
      prefix.lastIndexOf(" "),
      prefix.lastIndexOf("\t"),
      prefix.lastIndexOf("\n"),
      prefix.lastIndexOf("["),
      prefix.lastIndexOf("\""),
      prefix.lastIndexOf("$") - 1
    );
    // For $var, we want to replace including the $ itself — so bump tokenStart
    // back by 1 when the inserted text starts with $.
    const leftKeep = s.insertText.startsWith("$")
      ? Math.min(prefix.lastIndexOf("$"), prefix.length)
      : tokenStart + 1;
    const newValue =
      value.slice(0, leftKeep) + s.insertText + suffix;
    setValue(newValue);
    const newCursor = leftKeep + s.insertText.length;
    setCursor(newCursor);
    setTimeout(() => {
      inputRef.current?.focus();
      inputRef.current?.setSelectionRange(newCursor, newCursor);
    }, 0);
    return newValue;
  }

  async function ensureSession(): Promise<string | null> {
    if (sessionId) return sessionId;
    try {
      const id = await executor.spawn(runtimePlatform);
      setSession(id, runtimePlatform);
      return id;
    } catch (e) {
      showToast("err", `No se pudo iniciar el CLI: ${(e as Error).message ?? e}`);
      return null;
    }
  }

  function makeLogic(
    logicKind: "if" | "repeat" | "try" | "assert",
    partial: Partial<Block>,
  ): Block {
    return {
      id: `${logicKind}_${nanoid(8)}`,
      kind: "logic",
      logicKind,
      ...partial,
      meta: { status: "idle" },
    };
  }

  function parseRepeatHeader(args: string[]): RepeatMode {
    if (args.length === 0) {
      throw new Error("repeat necesita argumentos (N times / while / until / for)");
    }
    switch (args[0]) {
      case "while": {
        const pred = parsePredicate(args.slice(1), 0);
        return { mode: "while", pred };
      }
      case "until": {
        const pred = parsePredicate(args.slice(1), 0);
        return { mode: "until", pred };
      }
      case "for": {
        if (args.length < 4 || args[2] !== "in") {
          throw new Error("repeat for $var in $list");
        }
        return { mode: "foreach", variable: args[1], list: args[3] };
      }
      default: {
        const n = parseInt(args[0], 10);
        if (!Number.isInteger(n) || args.length < 2 || args[1] !== "times") {
          throw new Error("repeat N times");
        }
        return { mode: "times", n };
      }
    }
  }

  // Intenta interpretar el input como un keyword de control flow
  // (if/repeat/try/assert). Si matchea, crea un logic block estructural sin
  // ejecutar nada en el CLI y devuelve true. Si no matchea o el predicado
  // está mal formado, devuelve false para que el caller siga con runCurrent.
  function handleLogicKeyword(line: string): boolean {
    if (!flow) return false;
    const tokens = tokenizeLine(line);
    if (tokens.length === 0) return false;
    const head = tokens[0];
    if (!LOGIC_KEYWORDS.has(head)) return false;

    let block: Block | null = null;
    try {
      switch (head) {
        case "if": {
          const cond = parsePredicate(tokens.slice(1), 0);
          block = makeLogic("if", { predicate: cond, slots: [[], []] });
          break;
        }
        case "assert": {
          const cond = parsePredicate(tokens.slice(1), 0);
          block = makeLogic("assert", { predicate: cond, slots: [] });
          break;
        }
        case "repeat": {
          const repeat = parseRepeatHeader(tokens.slice(1));
          block = makeLogic("repeat", { repeat, slots: [[]] });
          break;
        }
        case "try": {
          block = makeLogic("try", { slots: [[], []] });
          break;
        }
      }
    } catch (e) {
      const msg = e instanceof Error ? e.message : String(e);
      showToast("err", `✗ sintaxis inválida: ${msg}`);
      // Dejamos el texto intacto para que el usuario corrija sin perder trabajo.
      return true;
    }

    if (block) {
      appendBlock(flow.id, block);
      setValue("");
      setCursor(0);
    }
    return true;
  }

  async function runCurrent() {
    let line = value.trim();
    if (!line || !flow) return;
    setInputError(null);

    // Keyword de control flow → no va al CLI; crea logic block estructural.
    if (handleLogicKeyword(line)) return;

    // Validación contra el catálogo (#180): texto que no empieza con un
    // comando conocido NO se inserta como bloque ni se ejecuta — feedback
    // inline y el texto queda intacto para corregir.
    if (!matchCommandLine(line, runtimePlatform)) {
      const head = line.split(/\s+/)[0];
      setInputError(`comando desconocido: «${head}» — no está en el catálogo (${runtimePlatform})`);
      return;
    }

    // Auto-inyectar --observer en `launch <bundleId>` (solo iOS) para que el
    // Simulator deje de tomar foco en los subsequent tree/inspect.
    // No se agrega si ya está presente o si es Android.
    if (runtimePlatform === "ios") {
      const tokens = line.split(/\s+/);
      if (tokens[0] === "launch" && tokens.length >= 2 && !tokens.includes("--observer")) {
        line = `${line} --observer`;
      }
    }

    const blockId = `blk_${nanoid(8)}`;
    const block: Block = {
      id: blockId,
      kind: "command",
      command: line,
      args: {},
      meta: { status: "running", ranAt: Date.now() },
    };
    appendBlock(flow.id, block);
    setValue("");
    setCursor(0);
    setRunning(true);

    const sess = await ensureSession();
    if (!sess) {
      updateBlock(flow.id, blockId, {
        meta: { status: "err", error: "sin sesion del CLI" },
      });
      setRunning(false);
      return;
    }

    let frame: Frame;
    try {
      frame = await executor.send(sess, line, 30_000);
    } catch (e) {
      updateBlock(flow.id, blockId, {
        meta: { status: "err", error: (e as Error).message ?? String(e) },
      });
      setRunning(false);
      return;
    }

    if (frame.ok) {
      updateBlock(flow.id, blockId, {
        meta: { status: "ok", ms: frame.ms, ranAt: Date.now() },
      });
      pushRecent(block);
      bumpRefreshTick();   // refresh reactivo del preview
      showToast("ok", `✓ ${line} (${frame.ms ?? 0}ms)`);
    } else {
      updateBlock(flow.id, blockId, {
        meta: {
          status: "err",
          ms: frame.ms,
          error: frame.err ?? frame.out ?? "fallo desconocido",
        },
      });
      showToast("err", `✗ ${line}: ${frame.err ?? "error"}`);
    }
    setRunning(false);
  }

  function onKeyDown(e: React.KeyboardEvent<HTMLInputElement>) {
    if (e.key === "ArrowDown") {
      e.preventDefault();
      setNavigated(true);
      setActiveIndex((i) => Math.min(i + 1, Math.max(suggestions.length - 1, 0)));
    } else if (e.key === "ArrowUp") {
      e.preventDefault();
      setNavigated(true);
      setActiveIndex((i) => Math.max(i - 1, 0));
    } else if (e.key === "Tab" && suggestions.length > 0) {
      e.preventDefault();
      pickSuggestion(suggestions[activeIndex]);
    } else if (e.key === "Enter") {
      e.preventDefault();
      // Enter con el predictivo abierto ACEPTA la sugerencia seleccionada
      // (#180) — antes inyectaba el prefijo crudo como bloque. Solo ejecuta
      // cuando la sugerencia ya está aplicada (aceptar sería un no-op) o
      // cuando no hay popover.
      if (popoverVisible) {
        const token = tokenize(value, cursor).token;
        if (navigated || token.length > 0) {
          const newValue = pickSuggestion(suggestions[activeIndex]);
          if (newValue !== value) return; // completado; el próximo Enter ejecuta
        }
      }
      setDismissed(true);
      void runCurrent();
    } else if (e.key === "Escape") {
      // First Escape just dismisses the popover; second clears the value.
      if (!dismissed) {
        setDismissed(true);
      } else {
        setValue("");
        setDismissed(false);
      }
      setInputError(null);
    }
  }

  const disabled = !flow;

  // Popover is visible when: input is focused, user has typed (or kept the
  // query), hasn't explicitly dismissed via Escape, and there are suggestions.
  const popoverVisible =
    !disabled &&
    focused &&
    !dismissed &&
    value.trim().length > 0 &&
    suggestions.length > 0;

  return (
    <div
      className={`command-bar${inputError ? " has-error" : ""}`}
      style={{ position: "relative" }}
      data-testid="command-bar"
    >
      <span className="slash" aria-hidden="true">
        /
      </span>
      <input
        ref={inputRef}
        id="command-bar-input"
        data-testid="command-bar-input"
        type="text"
        placeholder={
          disabled
            ? "Selecciona un flow para empezar"
            : `Escribe un comando — ${runtimePlatform}`
        }
        disabled={disabled}
        value={value}
        onChange={(e) => {
          setValue(e.target.value);
          setCursor(e.target.selectionStart ?? e.target.value.length);
          setDismissed(false);
          setInputError(null);
        }}
        onKeyDown={onKeyDown}
        onClick={(e) => {
          setCursor((e.target as HTMLInputElement).selectionStart ?? 0);
        }}
        onKeyUp={(e) => {
          setCursor((e.target as HTMLInputElement).selectionStart ?? 0);
        }}
        onFocus={() => setFocused(true)}
        onBlur={() =>
          // Give click-on-suggestion a chance to fire before hiding.
          setTimeout(() => setFocused(false), 100)
        }
        autoComplete="off"
        spellCheck={false}
      />
      {inputError ? (
        <span className="command-bar-error" data-testid="command-bar-error" role="alert">
          ✗ {inputError}
        </span>
      ) : (
        <span style={{ color: "var(--fg-faint)", fontSize: 11, fontFamily: "JetBrains Mono, monospace" }}>
          <span className="kbd">⏎</span> run <span style={{ color: "var(--fg-mute)", margin: "0 6px" }}>·</span>{" "}
          <span className="kbd">⎋</span> cancel
        </span>
      )}
      {popoverVisible && (
        <AutocompletePopover
          suggestions={suggestions}
          activeIndex={activeIndex}
          onPick={(s) => {
            pickSuggestion(s);
            setDismissed(false);
          }}
          onHover={setActiveIndex}
        />
      )}
    </div>
  );
}
