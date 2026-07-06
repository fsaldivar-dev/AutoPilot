import { useEffect, useMemo, useRef, useState } from "react";
import {
  applySuggestion,
  appSuggestionSources,
  expectationAt,
  signatureHelpAt,
  suggest,
  tokenize,
} from "./autocomplete";
import { AutocompletePopover } from "./AutocompletePopover";
import { matchCommandLine } from "./catalog";
import { selectCurrentProject, useStore } from "../state/store";
import { ensureFreshElements } from "../services/elements";
import { BINDING_RE } from "../services/flowRunner";
import type { Suggestion } from "../domain/types";

// Keywords de control flow: la edición inline puede convertir la línea en
// estructura al próximo round-trip código↔bloques — no se validan contra el
// catálogo de comandos (paridad con CommandBar, #180).
const LOGIC_KEYWORDS = new Set(["if", "repeat", "try", "assert"]);

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
  // true si el usuario navegó el popover con ↑/↓ (Enter entonces acepta la
  // sugerencia seleccionada en vez de guardar) — paridad con CommandBar (#180).
  const [navigated, setNavigated] = useState(false);
  const [inputError, setInputError] = useState<string | null>(null);
  const inputRef = useRef<HTMLInputElement>(null);

  const project = useStore(selectCurrentProject);
  const elements = useStore((s) => s.elements);
  const recents = useStore((s) => s.recentBlocks);
  const detectedApp = useStore((s) => s.detectedApp);
  const installedApps = useStore((s) => s.installedApps);
  const components = project?.components ?? [];
  const envVars = project?.env ?? [];

  const apps = useMemo(
    () => appSuggestionSources(project, detectedApp, installedApps),
    [project, detectedApp, installedApps]
  );

  useEffect(() => {
    inputRef.current?.focus();
    inputRef.current?.setSelectionRange(initial.length, initial.length);
  }, []);

  const suggestions: Suggestion[] = useMemo(
    () => suggest({ input: value, cursor, platform, elements, components, envVars, recents, apps }),
    [value, cursor, platform, elements, components, envVars, recents, apps]
  );

  useEffect(() => { setActiveIndex(0); }, [value]);

  // Signature help + hints contextuales (#185).
  const signature = useMemo(
    () => signatureHelpAt(value, cursor, platform),
    [value, cursor, platform]
  );
  const expectation = useMemo(
    () => expectationAt(value, cursor, platform),
    [value, cursor, platform]
  );
  const needsTree =
    expectation.kind === "param" &&
    expectation.param.type === "element" &&
    elements.length === 0;

  const sessionId = useStore((s) => s.sessionId);
  // #189: auto-fetch de elementos con sesión viva — hint pasivo fuera.
  useEffect(() => {
    if (needsTree && sessionId) void ensureFreshElements(platform);
  }, [needsTree, sessionId, platform]);

  // Devuelve el nuevo value para que el caller (Enter) detecte si la
  // sugerencia ya estaba aplicada (aceptar sería no-op → guardar).
  function pick(s: Suggestion): string {
    const applied = applySuggestion(value, cursor, s.insertText);
    setValue(applied.value);
    setCursor(applied.cursor);
    setNavigated(false);
    setTimeout(() => {
      inputRef.current?.focus();
      inputRef.current?.setSelectionRange(applied.cursor, applied.cursor);
    }, 0);
    return applied.value;
  }

  // Guarda solo si la línea es un comando del catálogo o un keyword de
  // lógica; texto desconocido → error inline, NO se persiste (#182, misma
  // clase de bug que #180 en CommandBar).
  function saveCurrent() {
    const trimmed = value.trim();
    if (trimmed.length === 0) {
      onCancel();
      return;
    }
    const head = trimmed.split(/\s+/)[0];
    if (
      !LOGIC_KEYWORDS.has(head) &&
      !BINDING_RE.test(trimmed) &&
      !matchCommandLine(trimmed, platform)
    ) {
      setInputError(`comando desconocido: «${head}» — no está en el catálogo (${platform})`);
      return;
    }
    setInputError(null);
    onSave(trimmed);
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
    } else if (e.key === "Tab" && suggestions.length > 0 && !dismissed) {
      e.preventDefault();
      pick(suggestions[activeIndex]);
    } else if (e.key === "Enter") {
      e.preventDefault();
      // Enter con el predictivo abierto ACEPTA la sugerencia (#182) — antes
      // guardaba el prefijo crudo. Solo guarda cuando la sugerencia ya está
      // aplicada (aceptar sería no-op) o no hay popover.
      if (popoverVisible) {
        const token = tokenize(value, cursor).token;
        if (navigated || token.length > 0) {
          const newValue = pick(suggestions[activeIndex]);
          if (newValue !== value) return; // completado; el próximo Enter guarda
        }
      }
      saveCurrent();
    } else if (e.key === "Escape") {
      e.preventDefault();
      setInputError(null);
      if (!dismissed && suggestions.length > 0) setDismissed(true);
      else onCancel();
    }
  }

  const popoverVisible = !dismissed && value.trim().length > 0 && suggestions.length > 0;

  return (
    <div
      className={`block inline-editor${inputError ? " has-error" : ""}`}
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
          setNavigated(false);
          setInputError(null);
        }}
        onClick={(e) => setCursor((e.target as HTMLInputElement).selectionStart ?? 0)}
        onKeyUp={(e) => setCursor((e.target as HTMLInputElement).selectionStart ?? 0)}
        onKeyDown={onKeyDown}
        onBlur={() => setTimeout(() => onCancel(), 120)}
        autoComplete="off"
        spellCheck={false}
      />
      {inputError ? (
        <span className="command-bar-error" data-testid="inline-editor-error" role="alert">
          {inputError}
        </span>
      ) : needsTree ? (
        <span className="inline-editor-hint" data-testid="inline-editor-hint">
          {sessionId
            ? "cargando elementos del device…"
            : <>corre <span className="kbd">launch</span> para ver los elementos del device</>}
        </span>
      ) : signature && expectation.kind === "param" && !popoverVisible ? (
        <span className="inline-editor-hint" data-testid="inline-editor-hint">
          {signature.name}
          {signature.pre && ` ${signature.pre}`}{" "}
          <u style={{ color: "var(--violet-2)", textUnderlineOffset: 3 }}>{signature.active}</u>
          {signature.post && ` ${signature.post}`} → {signature.returns}
        </span>
      ) : (
        <span className="inline-editor-hint">
          <span className="kbd">⏎</span> guardar · <span className="kbd">⎋</span> cancelar
        </span>
      )}
      {popoverVisible && (
        <AutocompletePopover
          suggestions={suggestions}
          activeIndex={activeIndex}
          onPick={pick}
          onHover={setActiveIndex}
          signature={signature}
        />
      )}
    </div>
  );
}
