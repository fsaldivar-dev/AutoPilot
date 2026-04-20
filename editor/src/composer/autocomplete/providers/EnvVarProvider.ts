import type { CursorContext, EnvVar, Suggestion } from "../../../domain/types";

export function suggestEnvVars(
  ctx: CursorContext,
  vars: EnvVar[]
): Suggestion[] {
  // Only suggest after `$` sigil.
  if (!ctx.afterDollar) return [];

  // Dedup by key — prefer current scope (first wins).
  const seen = new Set<string>();
  const unique: EnvVar[] = [];
  for (const v of vars) {
    if (seen.has(v.key)) continue;
    seen.add(v.key);
    unique.push(v);
  }

  return unique.map((v) => ({
    id: `env:${v.scope}:${v.key}`,
    kind: "variable" as const,
    label: `$${v.key}`,
    detail: v.secret ? `"••••••••" (secure · ${v.scope})` : `"${v.value}" (${v.scope})`,
    insertText: `$${v.key}`,
    score: 1.2,
    icon: "$",
  }));
}
