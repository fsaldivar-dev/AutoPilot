import type {
  Block,
  Component,
  EnvVar,
  IndexedElement,
  Suggestion,
} from "../../domain/types";
import { suggestCommands } from "./providers/CommandProvider";
import { suggestComponents } from "./providers/ComponentProvider";
import { suggestElements } from "./providers/ElementProvider";
import { suggestEnvVars } from "./providers/EnvVarProvider";
import { suggestRecents } from "./providers/RecentProvider";
import { rankSuggestions } from "./rank";
import { tokenize } from "./tokenize";

export interface SuggestInput {
  input: string;
  cursor: number;
  platform: "ios" | "android";
  elements: IndexedElement[];
  components: Component[];
  envVars: EnvVar[];
  recents: Block[];
}

export function suggest(inp: SuggestInput): Suggestion[] {
  const ctx = tokenize(inp.input, inp.cursor);
  const all: Suggestion[] = [
    ...suggestCommands(ctx, inp.platform),
    ...suggestElements(ctx, inp.elements),
    ...suggestComponents(ctx, inp.components),
    ...suggestEnvVars(ctx, inp.envVars),
    ...suggestRecents(ctx, inp.recents),
  ];
  const query = ctx.token.replace(/^[$"]/, "");
  return rankSuggestions(all, query, 20);
}

export { tokenize } from "./tokenize";
export { rankSuggestions } from "./rank";
