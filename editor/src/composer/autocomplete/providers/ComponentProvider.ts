import type {
  Component,
  CursorContext,
  Suggestion,
} from "../../../domain/types";

function signatureOf(c: Component): string {
  const params = c.signature.map((p) => `${p.name}: ${p.type}`).join(", ");
  return `${c.name}(${params})${c.returnType ? ` → ${c.returnType}` : ""}`;
}

export function suggestComponents(
  ctx: CursorContext,
  components: Component[]
): Suggestion[] {
  if (ctx.afterDollar) return [];
  if (ctx.insideBrackets) return [];

  // Components appear as top-level suggestions (like commands) and also when
  // the user types `use <name>`.
  const afterUse = ctx.commandWord === "use";
  return components.map((c) => ({
    id: `comp:${c.id}`,
    kind: "component" as const,
    label: c.name,
    detail: `used ${c.usageCount}× · ${c.body.length} steps`,
    signature: signatureOf(c),
    insertText: afterUse ? c.name : `use ${c.name}`,
    score: afterUse ? 1.5 : 0.6,
    icon: "🧩",
  }));
}
