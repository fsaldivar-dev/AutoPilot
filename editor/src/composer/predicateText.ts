// Port TS de cli/Sources/AutoCore/ScriptParser.swift -> parsePredicate/parseOr/parseAnd/parseNot/parseAtom.
// Mantiene gramática idéntica al CLI: `not` > `and` > `or`, paréntesis explícitos.

import type { Predicate } from "../domain/types";

// ──────────────────────────────────────────────────────────────────────────────
// Serializer: Predicate → texto round-trippable

const UNQUOTED_KEYWORDS = new Set([
  "is", "of",
  "ios", "android",
  "portrait", "landscape",
  "dark", "light",
  "true", "false",
]);

// Operadores de comparación: NUNCA se quotean. Quotearlos corrompía el
// round-trip: `platform == "ios"` → `platform "==" ios` (#175 — las comillas
// migraban al operador porque `==` contiene chars no alfanuméricos).
const OPERATOR_TOKENS = new Set(["==", "!=", "<=", ">=", "<", ">"]);

function isNumeric(arg: string): boolean {
  return /^-?\d+(\.\d+)?$/.test(arg);
}

function quoteIfNeeded(arg: string): string {
  if (arg.length === 0) return '""';
  if (arg.startsWith("$")) return arg;                  // $var
  if (OPERATOR_TOKENS.has(arg)) return arg;             // == != < > <= >=
  if (UNQUOTED_KEYWORDS.has(arg.toLowerCase())) return arg;
  // Sin espacios ni chars especiales → sin comillas es seguro para round-trip
  // pero preferimos quotear strings "reales" para diferenciarlos de keywords.
  // Regla: si contiene espacio o char no alfanumérico → quote.
  if (/[^A-Za-z0-9_.]/.test(arg)) return `"${arg}"`;
  // Palabras que podrían parecer tokens (ej: nombres de elementos sin espacio)
  // → quote para preservar intención.
  return `"${arg}"`;
}

// El operando que sigue a un operador de comparación es un VALOR, no un
// keyword: se quotea (salvo $var / número / booleano). Así `platform == "ios"`
// round-trippea idéntico — las comillas se quedan en el valor.
function quoteValue(arg: string): string {
  if (arg.length === 0) return '""';
  if (arg.startsWith("$")) return arg;
  if (isNumeric(arg)) return arg;
  if (arg === "true" || arg === "false") return arg;
  return `"${arg}"`;
}

export function predicateToText(p: Predicate): string {
  switch (p.kind) {
    case "call": {
      if (p.args.length === 0) return p.name;
      const partsArgs = p.args.map((a, i) =>
        i > 0 && OPERATOR_TOKENS.has(p.args[i - 1]) ? quoteValue(a) : quoteIfNeeded(a),
      );
      return [p.name, ...partsArgs].join(" ");
    }
    case "and":
      return `${predicateToText(p.left)} and ${predicateToText(p.right)}`;
    case "or":
      return `${predicateToText(p.left)} or ${predicateToText(p.right)}`;
    case "not":
      return `not ${predicateToText(p.inner)}`;
  }
}

// ──────────────────────────────────────────────────────────────────────────────
// Parser: tokens → Predicate

export class PredicateParseError extends Error {
  constructor(public message: string, public line: number) {
    super(`line ${line}: ${message}`);
    this.name = "PredicateParseError";
  }
}

export function parsePredicate(tokens: string[], line: number): Predicate {
  const state = { tokens, idx: 0, line };
  const pred = parseOr(state);
  if (state.idx < state.tokens.length) {
    throw new PredicateParseError(
      `trailing tokens: ${state.tokens.slice(state.idx).join(" ")}`,
      line,
    );
  }
  return pred;
}

interface ParseState {
  tokens: string[];
  idx: number;
  line: number;
}

function parseOr(s: ParseState): Predicate {
  let left = parseAnd(s);
  while (s.idx < s.tokens.length && s.tokens[s.idx] === "or") {
    s.idx++;
    const right = parseAnd(s);
    left = { kind: "or", left, right };
  }
  return left;
}

function parseAnd(s: ParseState): Predicate {
  let left = parseNot(s);
  while (s.idx < s.tokens.length && s.tokens[s.idx] === "and") {
    s.idx++;
    const right = parseNot(s);
    left = { kind: "and", left, right };
  }
  return left;
}

function parseNot(s: ParseState): Predicate {
  if (s.idx < s.tokens.length && s.tokens[s.idx] === "not") {
    s.idx++;
    const inner = parseNot(s);
    return { kind: "not", inner };
  }
  return parseAtom(s);
}

function parseAtom(s: ParseState): Predicate {
  if (s.idx >= s.tokens.length) {
    throw new PredicateParseError("unexpected end of predicate", s.line);
  }
  if (s.tokens[s.idx] === "(") {
    s.idx++;
    const inner = parseOr(s);
    if (s.idx >= s.tokens.length || s.tokens[s.idx] !== ")") {
      throw new PredicateParseError("missing `)`", s.line);
    }
    s.idx++;
    return inner;
  }

  const boundary = new Set(["and", "or", "not", ")"]);
  const name = s.tokens[s.idx];
  s.idx++;
  const args: string[] = [];
  while (s.idx < s.tokens.length && !boundary.has(s.tokens[s.idx])) {
    args.push(s.tokens[s.idx]);
    s.idx++;
  }
  return { kind: "call", name, args };
}
