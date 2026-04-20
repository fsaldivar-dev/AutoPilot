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
import { suggestPredicates } from "./providers/PredicateProvider";
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

export function suggest(inp: SuggestInput & { predicateMode?: boolean }): Suggestion[] {
  const baseCtx = tokenize(inp.input, inp.cursor);
  const ctx: typeof baseCtx & { predicateMode?: boolean } = {
    ...baseCtx,
    predicateMode: inp.predicateMode === true,
  };
  const all: Suggestion[] = [
    ...suggestCommands(ctx, inp.platform),
    ...suggestPredicates(ctx),
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
