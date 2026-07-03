import type { Block, Component } from "../domain/types";

interface Props {
  block: Block;
  component?: Component;
  selected?: boolean;
  onSelect?: (id: string, additive: boolean) => void;
  onDelete?: (id: string) => void;
}

export function ComponentBlock({
  block,
  component,
  selected,
  onSelect,
  onDelete,
}: Props) {
  const sig = component
    ? component.signature.map((p) => `${p.name}: ${p.type}`).join(", ")
    : "";

  return (
    <div
      className={`block ${selected ? "selected" : ""} status-${block.meta.status}`}
      data-testid={`component-block-${block.id}`}
      data-block-id={block.id}
      data-block-kind="component"
      onClick={(e) => onSelect?.(block.id, e.metaKey || e.ctrlKey || e.shiftKey)}
      style={{
        outline: selected ? "2px solid var(--accent)" : undefined,
        background: "rgba(139, 92, 246, 0.06)",
        cursor: "pointer",
      }}
    >
      <span className="drag-handle" title="Arrastrar para reordenar" aria-hidden>⋮⋮</span>
      <span className="kind-badge" style={{ color: "var(--accent)" }}>
        🧩 component
      </span>
      <span className="command-text">
        <span className="keyword">use</span> {component?.name ?? "(missing)"}
        {sig && <span style={{ color: "var(--text-dim)" }}>({sig})</span>}
      </span>
      {onDelete && (
        <div className="block-actions">
          <button
            className="btn btn-icon btn-danger"
            onClick={(e) => {
              e.stopPropagation();
              onDelete(block.id);
            }}
            title="Remove"
          >
            ×
          </button>
        </div>
      )}
    </div>
  );
}
