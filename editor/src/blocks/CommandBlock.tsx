import type { Block } from "../domain/types";

interface Props {
  block: Block;
  selected?: boolean;
  onSelect?: (id: string, additive: boolean) => void;
  onEdit?: (id: string) => void;
  onRetry?: (id: string) => void;
  onDelete?: (id: string) => void;
}

export function CommandBlock({
  block,
  selected,
  onSelect,
  onEdit,
  onRetry,
  onDelete,
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

function renderCommand(cmd: string): React.ReactNode {
  // Simple tokenizer: first word is keyword, quoted strings are strings.
  const parts: React.ReactNode[] = [];
  let i = 0;
  let acc = "";
  let inString = false;
  while (i < cmd.length) {
    const ch = cmd[i];
    if (ch === '"') {
      if (!inString) {
        if (acc) parts.push(<span key={parts.length}>{acc}</span>);
        acc = '"';
        inString = true;
      } else {
        acc += '"';
        parts.push(
          <span key={parts.length} className="string">
            {acc}
          </span>
        );
        acc = "";
        inString = false;
      }
    } else {
      acc += ch;
    }
    i++;
  }
  if (acc) parts.push(<span key={parts.length}>{acc}</span>);

  // Highlight first word as keyword if it's not a quoted string.
  if (parts.length > 0) {
    const first = parts[0];
    const text = typeof (first as any)?.props?.children === "string" ? (first as any).props.children as string : "";
    if (text && !text.startsWith('"')) {
      const firstWord = text.split(/\s+/)[0];
      const rest = text.slice(firstWord.length);
      parts[0] = (
        <span key="kw">
          <span className="keyword">{firstWord}</span>
          {rest}
        </span>
      );
    }
  }
  return parts;
}

function formatMs(ms: number): string {
  if (ms < 1000) return `${Math.round(ms)}ms`;
  return `${(ms / 1000).toFixed(1)}s`;
}
