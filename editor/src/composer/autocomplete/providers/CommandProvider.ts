import type { CursorContext, Suggestion } from "../../../domain/types";
import { commandsForPlatform, renderSignature } from "../../catalog";
import type { Expectation } from "../expectation";

export function suggestCommands(
  ctx: CursorContext & { expectation?: Expectation },
  platform: "ios" | "android"
): Suggestion[] {
  if (ctx.afterDollar) return [];
  if (ctx.insideBrackets) return [];
  if (ctx.afterWithin) return [];
  // #185: comandos SOLO en la región del nombre — jamás en posición de
  // argumento (antes: `launch ` ofrecía ping/list/boot…).
  if (ctx.expectation && ctx.expectation.kind !== "command") return [];

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
