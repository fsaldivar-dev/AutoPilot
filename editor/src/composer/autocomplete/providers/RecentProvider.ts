import type { Block, CursorContext, Suggestion } from "../../../domain/types";

export function suggestRecents(
  ctx: CursorContext,
  recents: Block[]
): Suggestion[] {
  if (ctx.insideBrackets || ctx.afterDollar || ctx.afterWithin) return [];
  // Recent blocks show up as quick-repeat suggestions.
  return recents
    .filter((b) => b.kind === "command" && !!b.command)
    .slice(0, 5)
    .map((b, i) => ({
      id: `rec:${b.id}`,
      kind: "recent" as const,
      label: b.command ?? "",
      detail: "recent",
      insertText: b.command ?? "",
      score: 0.3 - i * 0.05,
      icon: "🔁",
    }));
}
