import { useEffect, useMemo, useRef, useState } from "react";
import { suggest } from "./autocomplete";
import { AutocompletePopover } from "./AutocompletePopover";
import { selectCurrentProject, useStore } from "../state/store";
import type { Suggestion } from "../domain/types";

interface Props {
  initial: string;
  platform: "ios" | "android";
  onSave: (newCommand: string) => void;
  onCancel: () => void;
}

// Compact in-place editor for an existing block. Shares autocomplete
// with CommandBar — all 5 providers (Command / Element / Component /
// EnvVar / Recent).
export function InlineCommandEditor({ initial, platform, onSave, onCancel }: Props) {
  const [value, setValue] = useState(initial);
  const [cursor, setCursor] = useState(initial.length);
  const [activeIndex, setActiveIndex] = useState(0);
  const [dismissed, setDismissed] = useState(false);
  const inputRef = useRef<HTMLInputElement>(null);

  const project = useStore(selectCurrentProject);
  const elements = useStore((s) => s.elements);
  const recents = useStore((s) => s.recentBlocks);
  const components = project?.components ?? [];
  const envVars = project?.env ?? [];

  useEffect(() => {
    inputRef.current?.focus();
    inputRef.current?.setSelectionRange(initial.length, initial.length);
  }, []);

  const suggestions: Suggestion[] = useMemo(
    () => suggest({ input: value, cursor, platform, elements, components, envVars, recents }),
    [value, cursor, platform, elements, components, envVars, recents]
  );

  useEffect(() => { setActiveIndex(0); }, [value]);

  function pick(s: Suggestion) {
    const prefix = value.slice(0, cursor);
    const suffix = value.slice(cursor);
    const tokenStart = Math.max(
      prefix.lastIndexOf(" "),
      prefix.lastIndexOf("\t"),
      prefix.lastIndexOf("["),
      prefix.lastIndexOf("\""),
      prefix.lastIndexOf("$") - 1
    );
    const leftKeep = s.insertText.startsWith("$")
      ? Math.min(prefix.lastIndexOf("$"), prefix.length)
      : tokenStart + 1;
    const newValue = value.slice(0, leftKeep) + s.insertText + suffix;
    setValue(newValue);
    const newCursor = leftKeep + s.insertText.length;
    setCursor(newCursor);
    setTimeout(() => {
      inputRef.current?.focus();
      inputRef.current?.setSelectionRange(newCursor, newCursor);
    }, 0);
  }

  function onKeyDown(e: React.KeyboardEvent<HTMLInputElement>) {
    if (e.key === "ArrowDown") {
      e.preventDefault();
      setActiveIndex((i) => Math.min(i + 1, Math.max(suggestions.length - 1, 0)));
    } else if (e.key === "ArrowUp") {
      e.preventDefault();
      setActiveIndex((i) => Math.max(i - 1, 0));
    } else if (e.key === "Tab" && suggestions.length > 0 && !dismissed) {
      e.preventDefault();
      pick(suggestions[activeIndex]);
    } else if (e.key === "Enter") {
      e.preventDefault();
      const trimmed = value.trim();
      if (trimmed.length === 0) onCancel();
      else onSave(trimmed);
    } else if (e.key === "Escape") {
      e.preventDefault();
      if (!dismissed && suggestions.length > 0) setDismissed(true);
      else onCancel();
    }
  }

  const popoverVisible = !dismissed && value.trim().length > 0 && suggestions.length > 0;

  return (
    <div
      className="block inline-editor"
      data-testid="inline-editor"
      onClick={(e) => e.stopPropagation()}
    >
      <span className="slash" aria-hidden>/</span>
      <input
        ref={inputRef}
        className="inline-editor-input"
        value={value}
        onChange={(e) => {
          setValue(e.target.value);
          setCursor(e.target.selectionStart ?? e.target.value.length);
          setDismissed(false);
        }}
        onClick={(e) => setCursor((e.target as HTMLInputElement).selectionStart ?? 0)}
        onKeyUp={(e) => setCursor((e.target as HTMLInputElement).selectionStart ?? 0)}
        onKeyDown={onKeyDown}
        onBlur={() => setTimeout(() => onCancel(), 120)}
        autoComplete="off"
        spellCheck={false}
      />
      <span className="inline-editor-hint">
        <span className="kbd">⏎</span> guardar · <span className="kbd">⎋</span> cancelar
      </span>
      {popoverVisible && (
        <AutocompletePopover
          suggestions={suggestions}
          activeIndex={activeIndex}
          onPick={pick}
          onHover={setActiveIndex}
        />
      )}
    </div>
  );
}
