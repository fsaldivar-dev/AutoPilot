// Lenguaje `.auto` para Monaco: tokenizer Monarch, tema "autopilot" (Tokyo
// Night sobre la paleta del composer), mapeo de errores del parser a markers
// y builders puros de sugerencias para el CompletionProvider.
//
// Este módulo es puro a propósito — NO importa `monaco-editor` en runtime
// (solo tipos, que se borran al compilar) para que sea testeable en vitest
// sin levantar el editor. El wiring con Monaco vive en `setupMonaco.ts`.

import type * as monaco from "monaco-editor";
import { CATALOG, renderSignature, type CatalogCommand } from "../catalog";
import type { ParseError } from "../../domain/autoSerializer";
import type { IndexedElement } from "../../domain/types";

export const AUTO_LANGUAGE_ID = "autopilot-auto";
export const AUTO_THEME_ID = "autopilot";

// ── Keywords ─────────────────────────────────────────────────────────────────

// Control flow del parser estructural (autoSerializer.ts) + operadores de
// predicados (predicateText.ts).
export const CONTROL_KEYWORDS = [
  "if",
  "else",
  "end",
  "repeat",
  "times",
  "while",
  "until",
  "try",
  "catch",
  "assert",
  "for",
  "in",
] as const;

export const PREDICATE_OPERATORS = ["and", "or", "not"] as const;

// Primer token de cada comando del catálogo ("tree deep" → "tree").
export function catalogHeadWords(catalog: CatalogCommand[] = CATALOG): string[] {
  const heads = new Set<string>();
  for (const c of catalog) heads.add(c.name.split(" ")[0]);
  return [...heads];
}

// Segundo token de comandos multi-palabra ("tree deep" → "deep"), excluyendo
// los que ya son comandos por sí mismos (p.ej. "list" en "accounts list").
export function catalogSubWords(catalog: CatalogCommand[] = CATALOG): string[] {
  const heads = new Set(catalogHeadWords(catalog));
  const subs = new Set<string>();
  for (const c of catalog) {
    const parts = c.name.split(" ");
    if (parts.length > 1 && !heads.has(parts[1])) subs.add(parts[1]);
  }
  return [...subs];
}

// ── Tokenizer Monarch ────────────────────────────────────────────────────────

export function buildMonarchLanguage(
  catalog: CatalogCommand[] = CATALOG,
): monaco.languages.IMonarchLanguage {
  return {
    defaultToken: "",
    ignoreCase: false,

    commands: catalogHeadWords(catalog),
    subcommands: catalogSubWords(catalog),
    controlKeywords: [...CONTROL_KEYWORDS],
    operators: [...PREDICATE_OPERATORS],

    tokenizer: {
      root: [
        // Comentarios: línea completa que empieza con # (el tokenizer del CLI
        // solo trata # como comentario a inicio de línea).
        [/^\s*#.*$/, "comment"],

        // Strings
        [/"([^"\\]|\\.)*$/, "string.invalid"],
        [/'([^'\\]|\\.)*$/, "string.invalid"],
        [/"/, { token: "string.quote", next: "@stringDouble" }],
        [/'/, { token: "string.quote", next: "@stringSingle" }],

        // Flags --x y variables $x
        [/--[\w-]+/, "annotation.flag"],
        [/\$[A-Za-z_][\w.]*/, "variable"],

        // Números (timeouts, índices, coordenadas)
        [/\d+(\.\d+)?/, "number"],

        // Palabras: control flow > operadores de predicado > comandos > subcomandos
        [
          /[A-Za-z][\w.-]*/,
          {
            cases: {
              "@controlKeywords": "keyword.control",
              "@operators": "keyword.operator",
              "@commands": "keyword.command",
              "@subcommands": "type.subcommand",
              "@default": "identifier",
            },
          },
        ],

        [/[,()[\]]/, "delimiter"],
        [/\s+/, "white"],
      ],

      stringDouble: [
        [/[^\\"]+/, "string"],
        [/\\./, "string.escape"],
        [/"/, { token: "string.quote", next: "@pop" }],
      ],

      stringSingle: [
        [/[^\\']+/, "string"],
        [/\\./, "string.escape"],
        [/'/, { token: "string.quote", next: "@pop" }],
      ],
    },
  } as monaco.languages.IMonarchLanguage;
}

export const AUTO_LANGUAGE_CONF: monaco.languages.LanguageConfiguration = {
  comments: { lineComment: "#" },
  brackets: [["[", "]"], ["(", ")"]],
  autoClosingPairs: [
    { open: "[", close: "]" },
    { open: "(", close: ")" },
    { open: '"', close: '"' },
    { open: "'", close: "'" },
  ],
  surroundingPairs: [
    { open: '"', close: '"' },
    { open: "'", close: "'" },
    { open: "[", close: "]" },
  ],
};

// ── Tema "autopilot" — Tokyo Night sobre la paleta del composer.css ─────────

export const AUTO_THEME: monaco.editor.IStandaloneThemeData = {
  base: "vs-dark",
  inherit: true,
  rules: [
    { token: "comment", foreground: "6b7190", fontStyle: "italic" },
    { token: "keyword.control", foreground: "a78bfa", fontStyle: "bold" },
    { token: "keyword.operator", foreground: "a78bfa" },
    { token: "keyword.command", foreground: "60a5fa" },
    { token: "type.subcommand", foreground: "7dd3fc" },
    { token: "string", foreground: "5eead4" },
    { token: "string.quote", foreground: "5eead4" },
    { token: "string.escape", foreground: "2dd4bf" },
    { token: "string.invalid", foreground: "fb7185", fontStyle: "underline" },
    { token: "number", foreground: "fbbf24" },
    { token: "variable", foreground: "fb7185" },
    { token: "annotation.flag", foreground: "e0af68" },
    { token: "identifier", foreground: "e4e7f1" },
    { token: "delimiter", foreground: "a0a6bd" },
  ],
  colors: {
    "editor.background": "#0b0c14",
    "editor.foreground": "#e4e7f1",
    "editor.lineHighlightBackground": "#141624",
    "editorLineNumber.foreground": "#454a66",
    "editorLineNumber.activeForeground": "#a0a6bd",
    "editorCursor.foreground": "#8b5cf6",
    "editor.selectionBackground": "#8b5cf640",
    "editorIndentGuide.background1": "#1a1d2e",
    "editorError.foreground": "#fb7185",
    "editorWidget.background": "#141624",
    "editorWidget.border": "#2a2d42",
    "editorSuggestWidget.background": "#141624",
    "editorSuggestWidget.selectedBackground": "#8b5cf630",
    "editorSuggestWidget.highlightForeground": "#a78bfa",
  },
};

// ── #176: ParseError → Monaco markers ────────────────────────────────────────

// monaco.MarkerSeverity.Error — constante literal para no importar monaco
// en runtime desde un módulo puro.
export const MARKER_SEVERITY_ERROR = 8;

export interface AutoMarkerData {
  severity: number;
  message: string;
  startLineNumber: number;
  startColumn: number;
  endLineNumber: number;
  endColumn: number;
}

// Mapea los errores del parser TS (línea 1-based, sin columna) a markers de
// Monaco cubriendo el contenido útil de la línea (squiggle bajo el texto, no
// bajo la indentación). Clampea líneas fuera de rango (buffer editado a mitad
// de un parse) a la última línea real.
export function parseErrorsToMarkers(
  errors: ParseError[],
  source: string,
): AutoMarkerData[] {
  const lines = source.split(/\r?\n/);
  const lastLine = Math.max(lines.length, 1);
  return errors.map((err) => {
    const lineNumber = Math.min(Math.max(err.line, 1), lastLine);
    const text = lines[lineNumber - 1] ?? "";
    const trimmedEnd = text.replace(/\s+$/, "");
    const firstNonWs = text.length - text.trimStart().length;
    const startColumn = trimmedEnd.length > 0 ? firstNonWs + 1 : 1;
    const endColumn = Math.max(trimmedEnd.length + 1, startColumn + 1);
    return {
      severity: MARKER_SEVERITY_ERROR,
      message: err.message,
      startLineNumber: lineNumber,
      startColumn,
      endLineNumber: lineNumber,
      endColumn,
    };
  });
}

// ── Autocomplete: builders puros de sugerencias ──────────────────────────────

export interface AutoCompletionSpec {
  label: string;
  kind: "command" | "element";
  detail: string;
  documentation?: string;
  insertText: string;
  sortText: string;
}

export function buildCommandCompletions(
  catalog: CatalogCommand[] = CATALOG,
): AutoCompletionSpec[] {
  return catalog.map((c, i) => ({
    label: c.name,
    kind: "command" as const,
    detail: renderSignature(c),
    documentation: `${c.description}\n\nEjemplo: ${c.example}\nPlataforma: ${c.platform}`,
    insertText: c.name,
    sortText: `1_${String(i).padStart(3, "0")}`,
  }));
}

export function buildElementCompletions(
  elements: IndexedElement[],
): AutoCompletionSpec[] {
  return elements
    .filter((e) => e.label.trim().length > 0)
    .map((e) => ({
      label: `"${e.label}"`,
      kind: "element" as const,
      detail: `${e.role} · ${e.frame}`,
      documentation: `Elemento $${e.index} del device conectado`,
      insertText: `"${e.label}"`,
      sortText: `0_${String(e.index).padStart(3, "0")}`,
    }));
}

// Comandos cuyo primer parámetro es un target de UI (type: "element" en el
// catálogo) — tras ellos sugerimos labels reales del device.
export function targetCommands(catalog: CatalogCommand[] = CATALOG): Set<string> {
  const out = new Set<string>();
  for (const c of catalog) {
    if (c.params.some((p) => p.type === "element")) out.add(c.name.split(" ")[0]);
  }
  return out;
}

// ¿El texto de la línea hasta el cursor espera un target de elemento?
// (primer token es un comando con param element y ya hay un separador después)
export function lineExpectsElement(
  lineUntilCursor: string,
  catalog: CatalogCommand[] = CATALOG,
): boolean {
  const match = lineUntilCursor.match(/^\s*([A-Za-z][\w.-]*)(\s.*)?$/);
  if (!match || match[2] === undefined) return false;
  return targetCommands(catalog).has(match[1]);
}
