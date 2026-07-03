import type { Suggestion } from "../../domain/types";

// Score = exact prefix (2.0) + substring (1.0) + recency (0.5) + kind weight.

export function rankSuggestions(
  suggestions: Suggestion[],
  query: string,
  limit = 20
): Suggestion[] {
  const q = query.toLowerCase();
  const scored: Suggestion[] = [];
  for (const s of suggestions) {
    const label = s.label.toLowerCase();
    let score = s.score;
    if (q.length === 0) {
      score += 0.1;
    } else if (label.startsWith(q)) {
      score += 2.0;
    } else if (label.includes(q)) {
      score += 1.0;
    } else {
      // Antes: penalización -2.0 pero se mantenía en la lista → el popover
      // "siempre tenía sugerencias" aunque nada matcheara, y Enter/predictivo
      // operaba sobre basura (#180). Ahora los no-matches se descartan.
      continue;
    }
    scored.push({ ...s, score });
  }
  scored.sort((a, b) => b.score - a.score);
  return scored.slice(0, limit);
}
