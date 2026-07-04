import type { Block, CursorContext, Suggestion } from "../../../domain/types";
import { tokenizeLine } from "../../../domain/autoTokenize";
import type { Expectation } from "../expectation";

// Valores para el parámetro activo según su tipo en el catálogo (#185):
// enum → sus enumValues; boolean → true/false; string → valores recientes del
// mismo comando en la misma posición. number no sugiere nada (el signature
// help muestra el default). element lo cubre ElementProvider.
export function suggestParamValues(
  ctx: CursorContext & { expectation?: Expectation },
  recents: Block[]
): Suggestion[] {
  const exp = ctx.expectation;
  if (!exp || exp.kind !== "param") return [];
  const { command, param, paramIndex } = exp;

  if (param.type === "enum") {
    return (param.enumValues ?? []).map((v, i) => ({
      id: `val:enum:${v}`,
      kind: "value" as const,
      label: v,
      detail: param.name,
      insertText: v,
      score: 1.0 - i * 0.01,
      icon: "≡",
    }));
  }

  if (param.type === "boolean") {
    return ["true", "false"].map((v, i) => ({
      id: `val:bool:${v}`,
      kind: "value" as const,
      label: v,
      detail: param.name,
      insertText: v,
      score: 1.0 - i * 0.01,
      icon: "≡",
    }));
  }

  if (param.type === "string") {
    const nameWords = command.name.split(" ").length;
    const seen = new Set<string>();
    const out: Suggestion[] = [];
    for (const b of recents) {
      if (b.kind !== "command" || !b.command) continue;
      if (
        b.command !== command.name &&
        !b.command.startsWith(command.name + " ")
      ) {
        continue;
      }
      const value = tokenizeLine(b.command).slice(nameWords)[paramIndex];
      if (!value || value.startsWith("--") || seen.has(value)) continue;
      seen.add(value);
      out.push({
        id: `val:rec:${value}`,
        kind: "value" as const,
        label: `"${value}"`,
        detail: `${param.name} · reciente`,
        insertText: `"${value}"`,
        score: 1.1 - out.length * 0.05,
        icon: "🕘",
      });
    }
    return out;
  }

  return [];
}
