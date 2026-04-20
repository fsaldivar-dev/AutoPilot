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

export function renderSignature(cmd: CatalogCommand): string {
  const params = cmd.params
    .map((p) => (p.required === false ? `[${p.name}?]` : `${p.name}`))
    .join(" ");
  return `${cmd.name}${params ? " " + params : ""} → ${cmd.returns}`;
}
