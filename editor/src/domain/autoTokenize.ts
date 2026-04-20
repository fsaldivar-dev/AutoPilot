// Port 1:1 de cli/Sources/AutoCore/ScriptParser.swift -> tokenize(_:)
// Respeta quoted strings (" y '), colapsa whitespace.

export function tokenizeLine(line: string): string[] {
  const tokens: string[] = [];
  let current = "";
  let inQuote: string | null = null;

  for (const char of line) {
    if (inQuote !== null) {
      if (char === inQuote) {
        inQuote = null;
      } else {
        current += char;
      }
    } else if (char === '"' || char === "'") {
      inQuote = char;
    } else if (char === " " || char === "\t") {
      if (current.length > 0) {
        tokens.push(current);
        current = "";
      }
    } else {
      current += char;
    }
  }
  if (current.length > 0) tokens.push(current);
  return tokens;
}

// Parsea el script entero en (lineNumber, tokens, raw) — skip comments y blanks.
// `raw` preserva el texto original trimmed de la línea: lo usamos en acciones
// para roundtrip exacto (tokens pierden la info de quoting).
// Mismo contrato base que cli/Sources/AutoCore/ScriptParser.swift -> parseScript(_:)
export interface TokenizedLine {
  lineNumber: number;
  tokens: string[];
  raw: string;
}

export function tokenizeScript(content: string): TokenizedLine[] {
  const result: TokenizedLine[] = [];
  const lines = content.split(/\r?\n/);
  for (let i = 0; i < lines.length; i++) {
    const trimmed = lines[i].trim();
    if (trimmed.length === 0 || trimmed.startsWith("#")) continue;
    const tokens = tokenizeLine(trimmed);
    if (tokens.length > 0) {
      result.push({ lineNumber: i + 1, tokens, raw: trimmed });
    }
  }
  return result;
}
