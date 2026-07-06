import type { Block, CursorContext, EnvVar, Suggestion } from "../../../domain/types";
import { tokenizeLine } from "../../../domain/autoTokenize";
import type { Expectation } from "../expectation";
import type { AppSource } from "../appsSources";

// Valores para el parámetro activo según su tipo en el catálogo (#185):
// enum → sus enumValues; boolean → true/false; string → apps del contexto
// (#187: proyecto/en pantalla/instaladas, solo para params bundleId) +
// valores recientes del mismo comando en la misma posición. number no
// sugiere nada (el signature help muestra el default). element lo cubre
// ElementProvider.
export function suggestParamValues(
  ctx: CursorContext & { expectation?: Expectation },
  recents: Block[],
  apps: AppSource[] = [],
  envVars: EnvVar[] = []
): Suggestion[] {
  const exp = ctx.expectation;
  if (!exp || exp.kind !== "param") return [];
  const { command, param, paramIndex } = exp;

  // #194 — param de imagen: los assets del proyecto (variables scope
  // "asset") se ofrecen como $nombre; flowRunner los sustituye al correr.
  if (param.type === "image") {
    return envVars
      .filter((v) => v.scope === "asset")
      .map((v, i) => ({
        id: `val:asset:${v.key}`,
        kind: "value" as const,
        label: `$${v.key}`,
        detail: `${v.value} · asset`,
        insertText: `$${v.key}`,
        score: 1.2 - i * 0.02,
        icon: "🖼",
      }));
  }

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

    // #187 — bundleId con fuentes reales: proyecto > en pantalla > instaladas.
    if (param.name === "bundleId") {
      const scoreFor: Record<AppSource["source"], number> = {
        proyecto: 1.4,
        "en pantalla": 1.3,
        instalada: 1.15,
      };
      for (const a of apps) {
        if (seen.has(a.bundle)) continue;
        seen.add(a.bundle);
        out.push({
          id: `val:app:${a.bundle}`,
          kind: "value" as const,
          label: `"${a.bundle}"`,
          detail: `${a.name} · ${a.source}`,
          insertText: `"${a.bundle}"`,
          score: scoreFor[a.source],
          icon: "📱",
        });
      }
    }

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
