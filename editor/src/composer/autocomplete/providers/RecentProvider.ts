import type { Block, CursorContext, Suggestion } from "../../../domain/types";
import type { Expectation } from "../expectation";

export function suggestRecents(
  ctx: CursorContext & { expectation?: Expectation },
  recents: Block[]
): Suggestion[] {
  if (ctx.insideBrackets || ctx.afterDollar || ctx.afterWithin) return [];
  // #185: repetir un comando completo solo aplica en la región del comando.
  if (ctx.expectation && ctx.expectation.kind !== "command") return [];
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
