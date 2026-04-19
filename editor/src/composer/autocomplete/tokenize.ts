import type { CursorContext } from "../../domain/types";

// Tokenizes the command-bar input at the cursor position and classifies the
// context so autocomplete providers can decide what to show.

const ACTION_KEYWORDS = new Set([
  "tap",
  "doubleTap",
  "longPress",
  "clear",
  "scroll",
  "scrollTo",
  "type",
  "waitFor",
  "waitUntilGone",
  "exists",
  "copyTextFrom",
  "swipe",
  "drag",
  "inspect",
  "launch",
  "terminate",
  "install",
  "uninstall",
]);

export function tokenize(input: string, cursor: number): CursorContext {
  const prefix = input.slice(0, cursor);
  // Current word being typed — everything after the last whitespace or quote
  // or bracket boundary.
  const tokenStart = Math.max(
    prefix.lastIndexOf(" "),
    prefix.lastIndexOf("\t"),
    prefix.lastIndexOf("\n"),
    prefix.lastIndexOf("["),
    prefix.lastIndexOf("\"")
  );
  const token = prefix.slice(tokenStart + 1);

  // Are we between `[` and `]` on this line?
  const lastOpen = prefix.lastIndexOf("[");
  const lastClose = prefix.lastIndexOf("]");
  const insideBrackets = lastOpen > lastClose;

  // Did the previous meaningful word equal "within"?
  const tokens = prefix.split(/\s+/).filter(Boolean);
  const lastWord = tokens[tokens.length - 1];
  const prevWord = tokens[tokens.length - 2];
  const afterWithin =
    lastWord === "within" ||
    (prefix.endsWith(" ") && prevWord === "within" && !lastWord);

  // Is the cursor placed right after a `$` sigil (variable start)?
  const afterDollar = /\$[A-Za-z0-9_.]*$/.test(prefix);

  // Command word = first token on the current line.
  let commandWord: string | undefined;
  let paramIndex: number | undefined;
  if (tokens.length > 0) {
    commandWord = tokens[0];
    if (ACTION_KEYWORDS.has(commandWord)) {
      paramIndex = tokens.length - 1;
      if (prefix.endsWith(" ")) {
        paramIndex = tokens.length;
      }
    }
  }

  return {
    input,
    cursor,
    token,
    insideBrackets,
    afterWithin,
    afterDollar,
    commandWord,
    paramIndex,
  };
}

export function isActionKeyword(word: string): boolean {
  return ACTION_KEYWORDS.has(word);
}
