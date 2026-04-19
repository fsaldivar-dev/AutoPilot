import type { Suggestion } from "../../domain/types";

// Score = exact prefix (2.0) + substring (1.0) + recency (0.5) + kind weight.

export function rankSuggestions(
  suggestions: Suggestion[],
  query: string,
  limit = 20
): Suggestion[] {
  const q = query.toLowerCase();
  const scored = suggestions.map((s) => {
    const label = s.label.toLowerCase();
    let score = s.score;
    if (q.length === 0) {
      score += 0.1;
    } else if (label.startsWith(q)) {
      score += 2.0;
    } else if (label.includes(q)) {
      score += 1.0;
    } else {
      score -= 2.0;
    }
    return { ...s, score };
  });
  scored.sort((a, b) => b.score - a.score);
  return scored.slice(0, limit);
}
