import raw from "./commands.json";

export interface CatalogParam {
  name: string;
  type: "string" | "number" | "element" | "enum" | "boolean";
  required?: boolean;
  default?: string;
  enumValues?: string[];
}

export interface CatalogCommand {
  name: string;
  group: string;
  platform: "ios" | "android" | "both";
  description: string;
  params: CatalogParam[];
  example: string;
  returns: string;
}

export const CATALOG: CatalogCommand[] = (raw as { commands: CatalogCommand[] })
  .commands;

export function commandsForPlatform(
  platform: "ios" | "android"
): CatalogCommand[] {
  return CATALOG.filter(
    (c) => c.platform === "both" || c.platform === platform
  );
}

export function findCommand(name: string): CatalogCommand | undefined {
  return CATALOG.find((c) => c.name === name);
}

// Valida una línea completa contra el catálogo (#180): matchea el nombre de
// comando más largo que sea prefijo exacto de la línea. Los nombres pueden ser
// multi-palabra ("tree deep", "biometric enroll"), así que no basta con mirar
// el primer token. Devuelve undefined si la línea no empieza con ningún
// comando conocido para la plataforma.
export function matchCommandLine(
  line: string,
  platform: "ios" | "android"
): CatalogCommand | undefined {
  const trimmed = line.trim();
  let best: CatalogCommand | undefined;
  for (const c of commandsForPlatform(platform)) {
    if (trimmed === c.name || trimmed.startsWith(c.name + " ")) {
      if (!best || c.name.length > best.name.length) best = c;
    }
  }
  return best;
}

export function renderSignature(cmd: CatalogCommand): string {
  const params = cmd.params
    .map((p) => (p.required === false ? `[${p.name}?]` : `${p.name}`))
    .join(" ");
  return `${cmd.name}${params ? " " + params : ""} → ${cmd.returns}`;
}
