// Serializa flows a `.auto` y parsea `.auto` a flows.
//
// Port TS de la parte estructural de cli/Sources/AutoCore/ScriptParser.swift
// (parseStatements + parseIfStatement + parseRepeatStatement + parseTryStatement).
// El parser lee líneas ya tokenizadas por `autoTokenize.ts`. Los predicados van
// a `predicateText.ts` (parsePredicate).
//
// Sintaxis canónica: `end`-style (Pascal). Indentación es solo decorativa —
// el parser no depende de ella.

import type { Block, Flow, Predicate, RepeatMode } from "./types";
import { tokenizeScript, type TokenizedLine } from "./autoTokenize";
import { parsePredicate, predicateToText, PredicateParseError } from "../composer/predicateText";
import { nanoid } from "nanoid";

// ──────────────────────────────────────────────────────────────────────────────
// Serialize: Flow → .auto

export interface SerializeOptions {
  indent?: number;
}

export function serializeFlow(flow: Flow, opts?: SerializeOptions): string {
  const indent = opts?.indent ?? 2;
  return serializeBlocks(flow.blocks, 0, indent);
}

function serializeBlocks(blocks: Block[], depth: number, indent: number): string {
  const pad = " ".repeat(depth * indent);
  const lines: string[] = [];
  for (const b of blocks) {
    if (b.kind === "command" || b.kind === "component") {
      if (b.command) lines.push(pad + b.command);
    } else if (b.kind === "comment") {
      if (b.command) lines.push(pad + "# " + b.command);
    } else if (b.kind === "logic") {
      switch (b.logicKind) {
        case "if": {
          const cond = b.predicate ? predicateToText(b.predicate) : "";
          lines.push(pad + "if " + cond);
          const then_ = b.slots?.[0] ?? [];
          if (then_.length > 0) lines.push(serializeBlocks(then_, depth + 1, indent));
          const else_ = b.slots?.[1] ?? [];
          if (else_.length > 0) {
            lines.push(pad + "else");
            lines.push(serializeBlocks(else_, depth + 1, indent));
          }
          lines.push(pad + "end");
          break;
        }
        case "repeat": {
          const header = b.repeat ? repeatHeader(b.repeat) : "";
          lines.push(pad + "repeat " + header);
          const body = b.slots?.[0] ?? [];
          if (body.length > 0) lines.push(serializeBlocks(body, depth + 1, indent));
          lines.push(pad + "end");
          break;
        }
        case "try": {
          lines.push(pad + "try");
          const body = b.slots?.[0] ?? [];
          if (body.length > 0) lines.push(serializeBlocks(body, depth + 1, indent));
          const catch_ = b.slots?.[1] ?? [];
          if (catch_.length > 0) {
            lines.push(pad + "catch");
            lines.push(serializeBlocks(catch_, depth + 1, indent));
          }
          lines.push(pad + "end");
          break;
        }
        case "assert": {
          const cond = b.predicate ? predicateToText(b.predicate) : "";
          lines.push(pad + "assert " + cond);
          break;
        }
        default:
          // logicKind legacy (else/catch/foreach suelto) — ignorar silenciosamente
          break;
      }
    }
  }
  return lines.filter(l => l.length > 0).join("\n");
}

function repeatHeader(r: RepeatMode): string {
  switch (r.mode) {
    case "times":   return `${r.n} times`;
    case "while":   return "while " + predicateToText(r.pred);
    case "until":   return "until " + predicateToText(r.pred);
    case "foreach": return `for ${r.variable} in ${r.list}`;
  }
}

// ──────────────────────────────────────────────────────────────────────────────
// Parse: .auto → blocks

export interface ParseError {
  line: number;
  message: string;
}

export interface ParseResult {
  blocks: Block[];
  errors: ParseError[];
}

export function parseAuto(content: string): ParseResult {
  const lines = tokenizeScript(content);
  const errors: ParseError[] = [];
  const state = { lines, idx: 0, errors };
  try {
    const blocks = parseStatementBlock(state, new Set());
    if (state.idx < lines.length) {
      // `end` huérfano
      errors.push({
        line: lines[state.idx].lineNumber,
        message: `unexpected '${lines[state.idx].tokens[0]}' at top level`,
      });
    }
    return { blocks, errors };
  } catch (e) {
    if (e instanceof ParserError) {
      errors.push({ line: e.line, message: e.message });
      return { blocks: [], errors };
    }
    throw e;
  }
}

// ──────────────────────────────────────────────────────────────────────────────
// Internals

class ParserError extends Error {
  constructor(public msg: string, public line: number) {
    super(`line ${line}: ${msg}`);
    this.name = "ParserError";
  }
}

interface ParseState {
  lines: TokenizedLine[];
  idx: number;
  errors: ParseError[];
}

function mkMeta(): Block["meta"] { return { status: "idle" }; }
function newId(prefix: string): string { return `${prefix}_${nanoid(8)}`; }

function parseStatementBlock(s: ParseState, stopAt: Set<string>): Block[] {
  const out: Block[] = [];
  while (s.idx < s.lines.length) {
    const line = s.lines[s.idx];
    const head = line.tokens[0];
    if (stopAt.has(head)) return out;
    switch (head) {
      case "end":
        throw new ParserError("unexpected `end` (no matching block)", line.lineNumber);
      case "if":
        out.push(parseIf(s));
        break;
      case "repeat":
        out.push(parseRepeat(s));
        break;
      case "try":
        out.push(parseTry(s));
        break;
      case "assert":
        out.push(parseAssert(s));
        break;
      default:
        // Preservamos el texto original de la línea (raw) para que el roundtrip
        // serialize→parse→serialize quede estable sin hacer asunciones sobre
        // quoting de args.
        out.push({
          id: newId("blk"),
          kind: "command",
          command: line.raw,
          meta: mkMeta(),
        });
        s.idx++;
        break;
    }
  }
  return out;
}

function parseIf(s: ParseState): Block {
  const head = s.lines[s.idx];
  const predTokens = head.tokens.slice(1);
  const cond = tryParsePred(predTokens, head.lineNumber, s);
  s.idx++;
  const then_ = parseStatementBlock(s, new Set(["else", "end"]));
  if (s.idx >= s.lines.length) {
    throw new ParserError("unclosed `if` block", head.lineNumber);
  }
  let else_: Block[] = [];
  if (s.lines[s.idx].tokens[0] === "else") {
    s.idx++;
    else_ = parseStatementBlock(s, new Set(["end"]));
    if (s.idx >= s.lines.length) {
      throw new ParserError("unclosed `if` block", head.lineNumber);
    }
  }
  // ahora s.lines[s.idx] === "end"
  s.idx++;
  return {
    id: newId("if"),
    kind: "logic",
    logicKind: "if",
    predicate: cond,
    slots: [then_, else_],
    meta: mkMeta(),
  };
}

function parseRepeat(s: ParseState): Block {
  const head = s.lines[s.idx];
  const toks = head.tokens;
  if (toks.length < 2) {
    throw new ParserError("repeat missing arguments", head.lineNumber);
  }
  let repeat: RepeatMode;
  switch (toks[1]) {
    case "while": {
      const p = tryParsePred(toks.slice(2), head.lineNumber, s);
      repeat = { mode: "while", pred: p };
      break;
    }
    case "until": {
      const p = tryParsePred(toks.slice(2), head.lineNumber, s);
      repeat = { mode: "until", pred: p };
      break;
    }
    case "for": {
      // repeat for $var in $list
      if (toks.length < 5 || toks[3] !== "in") {
        throw new ParserError("expected `for $var in $list`", head.lineNumber);
      }
      repeat = { mode: "foreach", variable: toks[2], list: toks[4] };
      break;
    }
    default: {
      const n = parseInt(toks[1], 10);
      if (!Number.isInteger(n) || toks.length < 3 || toks[2] !== "times") {
        throw new ParserError(
          "expected `repeat N times`, `while`, `until`, or `for`",
          head.lineNumber,
        );
      }
      repeat = { mode: "times", n };
      break;
    }
  }
  s.idx++;
  const body = parseStatementBlock(s, new Set(["end"]));
  if (s.idx >= s.lines.length) {
    throw new ParserError("unclosed `repeat` block", head.lineNumber);
  }
  s.idx++;
  return {
    id: newId("rep"),
    kind: "logic",
    logicKind: "repeat",
    repeat,
    slots: [body],
    meta: mkMeta(),
  };
}

function parseTry(s: ParseState): Block {
  const head = s.lines[s.idx];
  s.idx++;
  const body = parseStatementBlock(s, new Set(["catch", "end"]));
  if (s.idx >= s.lines.length) {
    throw new ParserError("unclosed `try` block", head.lineNumber);
  }
  let catch_: Block[] = [];
  if (s.lines[s.idx].tokens[0] === "catch") {
    s.idx++;
    catch_ = parseStatementBlock(s, new Set(["end"]));
    if (s.idx >= s.lines.length) {
      throw new ParserError("unclosed `try` block", head.lineNumber);
    }
  }
  s.idx++; // consume `end`
  return {
    id: newId("try"),
    kind: "logic",
    logicKind: "try",
    slots: [body, catch_],
    meta: mkMeta(),
  };
}

function parseAssert(s: ParseState): Block {
  const head = s.lines[s.idx];
  const cond = tryParsePred(head.tokens.slice(1), head.lineNumber, s);
  s.idx++;
  return {
    id: newId("asrt"),
    kind: "logic",
    logicKind: "assert",
    predicate: cond,
    meta: mkMeta(),
  };
}

function tryParsePred(tokens: string[], line: number, s: ParseState): Predicate {
  try {
    return parsePredicate(tokens, line);
  } catch (e) {
    const msg = e instanceof PredicateParseError ? e.message : String(e);
    s.errors.push({ line, message: msg });
    // fallback — permite roundtrip básico con un predicado "falso"
    return { kind: "call", name: "exists", args: [""] };
  }
}

