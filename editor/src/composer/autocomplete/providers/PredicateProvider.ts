import type { CursorContext, Suggestion } from "../../../domain/types";

// Sugiere predicados + operadores cuando el popover está sobre un PredicateEditor
// (ctx.predicateMode === true). En el CommandBar normal NO aparece.

const PREDICATES: Array<{ label: string; insert: string; detail: string }> = [
  { label: "exists",        insert: 'exists "',      detail: "elemento existe" },
  { label: "visible",       insert: 'visible "',     detail: "elemento visible en viewport" },
  { label: "hasText",       insert: 'hasText "" "',  detail: 'elemento con texto "..."' },
  { label: "platform is",   insert: "platform is ",  detail: "ios | android" },
  { label: "orientation is",insert: "orientation is ", detail: "portrait | landscape" },
];

const OPERATORS: Array<{ label: string; insert: string; detail: string }> = [
  { label: "and", insert: "and ",  detail: "AND lógico" },
  { label: "or",  insert: "or ",   detail: "OR lógico" },
  { label: "not", insert: "not ",  detail: "NOT lógico" },
];

export function suggestPredicates(ctx: CursorContext): Suggestion[] {
  if (!ctx.predicateMode) return [];
  if (ctx.insideBrackets) return [];

  const token = ctx.token.toLowerCase();
  const out: Suggestion[] = [];

  for (const p of PREDICATES) {
    if (p.label.startsWith(token) || token.length === 0) {
      out.push({
        id: `pred:${p.label}`,
        kind: "command",
        label: p.label,
        detail: p.detail,
        insertText: p.insert,
        score: 0.5,
        icon: "🔍",
      });
    }
  }
  for (const op of OPERATORS) {
    if (op.label.startsWith(token) || token.length === 0) {
      out.push({
        id: `op:${op.label}`,
        kind: "command",
        label: op.label,
        detail: op.detail,
        insertText: op.insert,
        score: 0.3,
        icon: "∧",
      });
    }
  }
  return out;
}
