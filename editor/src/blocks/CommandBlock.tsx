import type { Block } from "../domain/types";

interface Props {
  block: Block;
  selected?: boolean;
  onSelect?: (id: string, additive: boolean) => void;
  onEdit?: (id: string) => void;
  onRetry?: (id: string) => void;
  onDelete?: (id: string) => void;
  onRun?: (id: string) => void;
  canRun?: boolean;
}

export function CommandBlock({
  block,
  selected,
  onSelect,
  onEdit,
  onRetry,
  onDelete,
  onRun,
  canRun,
}: Props) {
  const status = block.meta.status;
  const statusClass = `status-${status}`;

  return (
    <div
      className={`block ${statusClass} ${selected ? "selected" : ""}`}
      data-testid={`block-${block.id}`}
      data-block-id={block.id}
      data-block-kind={block.kind}
      data-block-status={status}
      onClick={(e) => onSelect?.(block.id, e.metaKey || e.ctrlKey || e.shiftKey)}
      style={{
        outline: selected ? "2px solid var(--accent)" : undefined,
        cursor: "pointer",
      }}
    >
      <span className="drag-handle" title="Arrastrar para reordenar" aria-hidden>⋮⋮</span>
      <span className="kind-badge">{block.kind}</span>
      <span className="command-text">{renderCommand(block.command ?? "")}</span>
      {block.meta.error && (
        <span className="error-detail" data-testid="block-error">
          {block.meta.error}
        </span>
      )}
      {block.meta.ms != null && (
        <span className="duration">⚡ {formatMs(block.meta.ms)}</span>
      )}
      <div className="block-actions">
        {onRun && canRun !== false && status !== "running" && (
          <button
            className="btn btn-icon btn-run-single"
            onClick={(e) => { e.stopPropagation(); onRun(block.id); }}
            title="Ejecutar solo este bloque"
            data-testid="block-run"
          >
            ▶
          </button>
        )}
        {status === "err" && onRetry && (
          <button className="btn btn-icon" onClick={(e) => { e.stopPropagation(); onRetry(block.id); }} title="Retry" data-testid="block-retry">
            ↻
          </button>
        )}
        {onEdit && (
          <button className="btn btn-icon" onClick={(e) => { e.stopPropagation(); onEdit(block.id); }} title="Edit">
            ✎
          </button>
        )}
        {onDelete && (
          <button className="btn btn-icon btn-danger" onClick={(e) => { e.stopPropagation(); onDelete(block.id); }} title="Delete">
            ×
          </button>
        )}
      </div>
    </div>
  );
}

const KEYWORDS = new Set([
  "tap", "type", "waitFor", "waitUntilGone", "screenshot", "swipe", "clear",
  "scroll", "scrollTo", "scrollUntilVisible", "launch", "terminate", "wait",
  "doubleTap", "longPress", "tapAt", "drag", "exists", "install", "uninstall",
  "boot", "shutdown", "media", "paste", "openurl", "permission", "biometric",
  "faceid", "rotate", "setAppearance", "setLocation", "lockDevice", "unlockDevice",
  "pushFile", "pullFile", "logs", "keychain", "startRecording", "stopRecording",
  "ping", "tree", "index", "list", "inspect", "record", "build", "config",
  "eraseText", "run", "if", "else", "repeat", "foreach", "try", "catch",
]);
const LOGIC_KEYWORDS = new Set(["if", "else", "repeat", "foreach", "try", "catch"]);

// Tokenize a command line into typed tokens for coloring:
//   keyword / logic / string / variable / number / indexRef / operator / word
function renderCommand(cmd: string): React.ReactNode {
  if (!cmd) return null;
  const tokens: { type: string; text: string }[] = [];
  let i = 0;
  let firstWord = true;
  while (i < cmd.length) {
    const ch = cmd[i];
    // whitespace — keep as literal
    if (/\s/.test(ch)) {
      let j = i;
      while (j < cmd.length && /\s/.test(cmd[j])) j++;
      tokens.push({ type: "ws", text: cmd.slice(i, j) });
      i = j;
      continue;
    }
    // quoted string "..."
    if (ch === '"') {
      let j = i + 1;
      while (j < cmd.length && cmd[j] !== '"') {
        if (cmd[j] === "\\" && j + 1 < cmd.length) j++;
        j++;
      }
      if (j < cmd.length) j++;
      tokens.push({ type: "string", text: cmd.slice(i, j) });
      i = j;
      firstWord = false;
      continue;
    }
    // $variable
    if (ch === "$") {
      let j = i + 1;
      while (j < cmd.length && /[A-Za-z0-9_.]/.test(cmd[j])) j++;
      tokens.push({ type: "variable", text: cmd.slice(i, j) });
      i = j;
      firstWord = false;
      continue;
    }
    // operator == != && ||
    if ("=!<>&|".includes(ch)) {
      let j = i;
      while (j < cmd.length && "=!<>&|".includes(cmd[j])) j++;
      tokens.push({ type: "operator", text: cmd.slice(i, j) });
      i = j;
      continue;
    }
    // [role] bracket
    if (ch === "[") {
      let j = i + 1;
      while (j < cmd.length && cmd[j] !== "]") j++;
      if (j < cmd.length) j++;
      tokens.push({ type: "bracket", text: cmd.slice(i, j) });
      i = j;
      continue;
    }
    // number
    if (/[0-9]/.test(ch)) {
      let j = i;
      while (j < cmd.length && /[0-9.,]/.test(cmd[j])) j++;
      tokens.push({ type: "number", text: cmd.slice(i, j) });
      i = j;
      firstWord = false;
      continue;
    }
    // word → keyword / logic / identifier
    let j = i;
    while (j < cmd.length && /[A-Za-z0-9_]/.test(cmd[j])) j++;
    if (j === i) {
      // Unknown single char (punctuation, accents, emojis) — consume 1 char
      // to guarantee forward progress. Otherwise we'd loop forever.
      tokens.push({ type: "word", text: cmd[i] });
      i++;
      continue;
    }
    const word = cmd.slice(i, j);
    let type: string;
    if (LOGIC_KEYWORDS.has(word)) type = "logic";
    else if (firstWord && KEYWORDS.has(word)) type = "keyword";
    else type = "word";
    tokens.push({ type, text: word });
    i = j;
    if (word.length > 0) firstWord = false;
  }
  return tokens.map((t, idx) =>
    t.type === "ws"
      ? t.text
      : <span key={idx} className={`tok-${t.type}`}>{t.text}</span>
  );
}

function formatMs(ms: number): string {
  if (ms < 1000) return `${Math.round(ms)}ms`;
  return `${(ms / 1000).toFixed(1)}s`;
}
