import { nanoid } from "nanoid";
import { useEffect, useMemo, useRef, useState } from "react";
import { suggest } from "./autocomplete";
import { AutocompletePopover } from "./AutocompletePopover";
import { useStore, selectCurrentFlow, selectCurrentProject } from "../state/store";
import type { Block, Frame, Platform, Suggestion } from "../domain/types";
import * as executor from "../services/executor";

interface Props {
  platform: Platform;
}

export function CommandBar({ platform }: Props) {
  const [value, setValue] = useState("");
  const [cursor, setCursor] = useState(0);
  const [activeIndex, setActiveIndex] = useState(0);
  const [focused, setFocused] = useState(false);
  const [dismissed, setDismissed] = useState(false);
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
    // Any typing clears the dismissed flag so the popover can re-appear.
    if (value.length > 0) setDismissed(false);
  }, [value]);

  function pickSuggestion(s: Suggestion) {
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

  async function runCurrent() {
    const line = value.trim();
    if (!line || !flow) return;

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
      setActiveIndex((i) => Math.min(i + 1, Math.max(suggestions.length - 1, 0)));
    } else if (e.key === "ArrowUp") {
      e.preventDefault();
      setActiveIndex((i) => Math.max(i - 1, 0));
    } else if (e.key === "Tab" && suggestions.length > 0) {
      e.preventDefault();
      pickSuggestion(suggestions[activeIndex]);
    } else if (e.key === "Enter") {
      e.preventDefault();
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
    <div className="command-bar" style={{ position: "relative" }} data-testid="command-bar">
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
      <span style={{ color: "var(--fg-faint)", fontSize: 11, fontFamily: "JetBrains Mono, monospace" }}>
        <span className="kbd">⏎</span> run <span style={{ color: "var(--fg-mute)", margin: "0 6px" }}>·</span>{" "}
        <span className="kbd">⎋</span> cancel
      </span>
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
