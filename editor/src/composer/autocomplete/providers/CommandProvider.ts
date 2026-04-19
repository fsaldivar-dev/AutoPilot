import type { CursorContext, Suggestion } from "../../../domain/types";
import { commandsForPlatform, renderSignature } from "../../catalog";

export function suggestCommands(
  ctx: CursorContext,
  platform: "ios" | "android"
): Suggestion[] {
  // If the cursor is clearly in an argument (we already identified a command
  // word and it's an action keyword), skip suggesting commands.
  if (ctx.afterDollar) return [];
  if (ctx.insideBrackets) return [];
  if (ctx.afterWithin) return [];

  return commandsForPlatform(platform).map((c) => ({
    id: `cmd:${c.name}`,
    kind: "command" as const,
    label: c.name,
    detail: c.description,
    signature: renderSignature(c),
    insertText: c.name + (c.params.length > 0 ? " " : ""),
    score: c.group === "interaction" ? 0.4 : 0.2,
    icon: iconFor(c.group),
  }));
}

function iconFor(group: string): string {
  switch (group) {
    case "interaction":
      return "👆";
    case "inspection":
      return "🔍";
    case "app":
      return "📱";
    case "capture":
      return "📸";
    case "biometric":
      return "🔒";
    case "camera":
      return "📷";
    case "env":
      return "🌎";
    case "files":
      return "📁";
    case "permissions":
      return "✅";
    case "keyboard":
      return "⌨️";
    case "diagnostic":
      return "🩺";
    default:
      return "⚙️";
  }
}
