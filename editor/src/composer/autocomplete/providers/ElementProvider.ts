import type {
  CursorContext,
  IndexedElement,
  Suggestion,
} from "../../../domain/types";
import { isActionKeyword } from "../tokenize";
import type { Expectation } from "../expectation";

const CONTAINER_HINTS = [
  "group",
  "toolbar",
  "list",
  "scrollarea",
  "table",
  "navigationbar",
  "tabbar",
];

export function suggestElements(
  ctx: CursorContext & { expectation?: Expectation },
  elements: IndexedElement[]
): Suggestion[] {
  // Elementos cuando (#185):
  // 1. La expectativa dice param tipo `element` o posición de predicado
  //    (exists "x" / visible "x")
  // 2. Tras `within ` (filtrados a contenedores)
  // 3. Dentro de `[...]`
  // 4. Sin expectativa (PredicateEditor): tras un action keyword — legacy
  const exp = ctx.expectation;
  const wantsElement = exp
    ? (exp.kind === "param" && exp.param.type === "element") ||
      exp.kind === "predicate" ||
      ctx.afterWithin ||
      ctx.insideBrackets
    : (ctx.commandWord && isActionKeyword(ctx.commandWord)) ||
      ctx.afterWithin ||
      ctx.insideBrackets;
  if (!wantsElement) return [];

  let filtered = elements;
  if (ctx.afterWithin) {
    filtered = elements.filter((e) =>
      CONTAINER_HINTS.some((h) => e.role.toLowerCase().includes(h))
    );
  }

  return filtered.map((e) => ({
    id: `el:${e.index}`,
    kind: "element" as const,
    label: `"${e.label}"`,
    detail: `${e.role} · ${e.frame}`,
    insertText: `"${e.label}"`,
    score: 0.9,
    icon: "🎯",
  }));
}
