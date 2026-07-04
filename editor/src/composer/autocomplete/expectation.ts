// Motor de expectativa (#185): deriva del catálogo qué tipo de token va en la
// posición del cursor. Es la única fuente de verdad del predictivo — los
// providers de suggest() y el CompletionProvider de Monaco (#186) consumen la
// misma expectativa, así el popover se comporta idéntico en Bloques y Código
// y un comando nuevo en commands.json obtiene autocompletado correcto gratis.

import {
  commandsForPlatform,
  type CatalogCommand,
  type CatalogParam,
} from "../catalog";

// Keywords de control flow: tras ellos viene un predicado, no un comando.
const PREDICATE_HEADS = new Set(["if", "assert"]);
const REPEAT_PREDICATE_MODES = new Set(["while", "until"]);

export type Expectation =
  // Cursor en la región del nombre de comando (primer/os token/s).
  | { kind: "command" }
  // Cursor sobre el parámetro `paramIndex` de un comando del catálogo.
  | {
      kind: "param";
      command: CatalogCommand;
      param: CatalogParam;
      paramIndex: number;
    }
  // Después de un `$` — variables.
  | { kind: "variable" }
  // Después de if/assert o repeat while/until — predicados.
  | { kind: "predicate" }
  // Después del último parámetro declarado (flags, texto libre): nada útil
  // que sugerir.
  | { kind: "rest"; command?: CatalogCommand };

// Split quote-aware del texto de argumentos. Devuelve los tokens y si el
// cursor está a mitad del último (aún tipeándolo) o tras un separador.
function splitArgs(rest: string): { args: string[]; midToken: boolean } {
  const args: string[] = [];
  let current = "";
  let inQuote: string | null = null;
  let hasCurrent = false;

  for (const ch of rest) {
    if (inQuote !== null) {
      if (ch === inQuote) inQuote = null;
      else current += ch;
      hasCurrent = true;
    } else if (ch === '"' || ch === "'") {
      inQuote = ch;
      hasCurrent = true;
    } else if (ch === " " || ch === "\t") {
      if (hasCurrent) {
        args.push(current);
        current = "";
        hasCurrent = false;
      }
    } else {
      current += ch;
      hasCurrent = true;
    }
  }
  if (hasCurrent) args.push(current);
  return { args, midToken: hasCurrent };
}

export function expectationAt(
  input: string,
  cursor: number,
  platform: "ios" | "android"
): Expectation {
  const prefix = input.slice(0, cursor);

  if (/\$[A-Za-z0-9_.]*$/.test(prefix)) return { kind: "variable" };

  const lead = prefix.length - prefix.trimStart().length;
  const body = prefix.slice(lead);

  // Predicados: `if `, `assert `, `repeat while|until `.
  const headMatch = body.match(/^(\S+)(\s|$)/);
  const head = headMatch?.[1] ?? "";
  if (PREDICATE_HEADS.has(head) && /\s/.test(body)) {
    return { kind: "predicate" };
  }
  if (head === "repeat") {
    const words = body.split(/\s+/).filter(Boolean);
    if (words.length >= 2 && REPEAT_PREDICATE_MODES.has(words[1])) {
      return { kind: "predicate" };
    }
    return { kind: "rest" };
  }

  // Comando del catálogo: el nombre más largo que sea prefijo de la línea
  // seguido de separador (mismo criterio que matchCommandLine).
  let matched: CatalogCommand | undefined;
  for (const c of commandsForPlatform(platform)) {
    if (body === c.name || body.startsWith(c.name + " ") || body.startsWith(c.name + "\t")) {
      if (!matched || c.name.length > matched.name.length) matched = c;
    }
  }

  // Si lo tipeado aún puede extenderse a un nombre más largo («tree d» →
  // «tree deep», «list b» → «list buttons»), seguimos en región de comando
  // aunque el prefijo ya matchee un comando más corto.
  if (
    body.length > 0 &&
    commandsForPlatform(platform).some(
      (c) => c.name.length > body.length && c.name.startsWith(body)
    )
  ) {
    return { kind: "command" };
  }

  if (!matched) {
    // ¿Lo tipeado aún puede ser el nombre (multi-palabra a medias, p.ej.
    // «biometric enr»)? Entonces seguimos en región de comando.
    const typed = body.replace(/\s+$/, " ");
    if (
      body.trim().length === 0 ||
      commandsForPlatform(platform).some(
        (c) => c.name.startsWith(typed) || c.name.startsWith(body.trim())
      )
    ) {
      return { kind: "command" };
    }
    // Head desconocido para el catálogo (componentes via `use`, texto libre):
    // primera palabra → command (rank filtra); después → rest.
    return /\s/.test(body.trim()) ? { kind: "rest" } : { kind: "command" };
  }

  const rest = body.slice(matched.name.length);
  if (rest.length === 0) return { kind: "command" };

  const { args, midToken } = splitArgs(rest);
  const paramIndex = midToken ? args.length - 1 : args.length;
  if (paramIndex >= matched.params.length) {
    return { kind: "rest", command: matched };
  }
  return {
    kind: "param",
    command: matched,
    param: matched.params[paramIndex],
    paramIndex,
  };
}

// Signature help: la firma del comando activo con el parámetro actual
// separado para que la UI lo subraye. null si el cursor no está en params.
export interface SignatureParts {
  name: string;
  pre: string;
  active: string;
  post: string;
  returns: string;
}

function paramLabel(p: CatalogParam): string {
  const base = p.default !== undefined ? `${p.name}=${p.default}` : p.name;
  return p.required === false ? `[${base}]` : base;
}

export function signatureHelpAt(
  input: string,
  cursor: number,
  platform: "ios" | "android"
): SignatureParts | null {
  const exp = expectationAt(input, cursor, platform);
  const command =
    exp.kind === "param" ? exp.command : exp.kind === "rest" ? exp.command : undefined;
  if (!command || command.params.length === 0) return null;
  const active = exp.kind === "param" ? exp.paramIndex : -1;
  const labels = command.params.map(paramLabel);
  return {
    name: command.name,
    pre: labels.slice(0, Math.max(active, 0)).join(" "),
    active: active >= 0 ? labels[active] : "",
    post: labels.slice(active >= 0 ? active + 1 : 0).join(" "),
    returns: command.returns,
  };
}
