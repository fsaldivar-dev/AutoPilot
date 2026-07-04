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
import { suggestParamValues } from "./providers/ParamValueProvider";
import { suggestPredicates } from "./providers/PredicateProvider";
import { suggestRecents } from "./providers/RecentProvider";
import { expectationAt } from "./expectation";
import { rankSuggestions } from "./rank";
import { tokenize } from "./tokenize";
import type { AppSource } from "./appsSources";

export interface SuggestInput {
  input: string;
  cursor: number;
  platform: "ios" | "android";
  elements: IndexedElement[];
  components: Component[];
  envVars: EnvVar[];
  recents: Block[];
  // Fuentes de bundleId (#187): proyecto/en pantalla/instaladas — ver
  // appSuggestionSources().
  apps?: AppSource[];
}

export function suggest(inp: SuggestInput & { predicateMode?: boolean }): Suggestion[] {
  const baseCtx = tokenize(inp.input, inp.cursor);
  // La expectativa (#185) decide qué providers aplican en esta posición —
  // en modo predicado (PredicateEditor) la línea no es un comando, así que
  // no se calcula contra el catálogo.
  const expectation = inp.predicateMode === true
    ? undefined
    : expectationAt(inp.input, inp.cursor, inp.platform);
  const ctx = {
    ...baseCtx,
    predicateMode: inp.predicateMode === true,
    expectation,
  };
  const all: Suggestion[] = [
    ...suggestCommands(ctx, inp.platform),
    ...suggestPredicates(ctx),
    ...suggestElements(ctx, inp.elements),
    ...suggestParamValues(ctx, inp.recents, inp.apps),
    ...suggestComponents(ctx, inp.components),
    ...suggestEnvVars(ctx, inp.envVars),
    ...suggestRecents(ctx, inp.recents),
  ];
  const query = ctx.token.replace(/^[$"]/, "");
  return rankSuggestions(all, query, 20);
}

export { tokenize } from "./tokenize";
export { rankSuggestions } from "./rank";
export { applySuggestion } from "./apply";
export { expectationAt, signatureHelpAt } from "./expectation";
export type { Expectation, SignatureParts } from "./expectation";
export { appSuggestionSources, parseAppsOutput } from "./appsSources";
export type { AppSource } from "./appsSources";
