import type {
  CursorContext,
  IndexedElement,
  Suggestion,
} from "../../../domain/types";
import { isActionKeyword } from "../tokenize";

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
  ctx: CursorContext,
  elements: IndexedElement[]
): Suggestion[] {
  // Elements are proposed in three situations:
  // 1. After an action keyword (tap, type, waitFor …)
  // 2. After `within ` (filtered to containers)
  // 3. Inside `[...]` brackets — we'll filter by role in RoleProvider
  // elsewhere; here we contribute element labels that match the role.
  const wantsElement =
    (ctx.commandWord && isActionKeyword(ctx.commandWord)) ||
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
