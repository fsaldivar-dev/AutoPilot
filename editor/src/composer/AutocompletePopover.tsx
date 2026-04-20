import type { Suggestion } from "../domain/types";

interface Props {
  suggestions: Suggestion[];
  activeIndex: number;
  onPick: (s: Suggestion) => void;
  onHover: (index: number) => void;
}

const SECTION_LABELS: Record<string, string> = {
  element: "Elements visible on device",
  component: "Project components",
  variable: "Environment variables",
  recent: "Recent",
  command: "Commands",
  role: "Roles",
  container: "Containers",
};

export function AutocompletePopover({
  suggestions,
  activeIndex,
  onPick,
  onHover,
}: Props) {
  if (suggestions.length === 0) return null;

  // Group suggestions by kind while preserving the global rank order.
  const groups = new Map<string, { suggestion: Suggestion; globalIndex: number }[]>();
  suggestions.forEach((s, globalIndex) => {
    const key = s.kind;
    if (!groups.has(key)) groups.set(key, []);
    groups.get(key)!.push({ suggestion: s, globalIndex });
  });

  return (
    <div className="autocomplete-popover" role="listbox" data-testid="autocomplete-popover">
      {Array.from(groups.entries()).map(([kind, items]) => (
        <div key={kind} data-ac-section={kind}>
          <div
            style={{
              padding: "6px 14px 2px",
              fontSize: 10,
              textTransform: "uppercase",
              letterSpacing: "0.1em",
              color: "var(--fg-faint)",
              fontWeight: 600,
              display: "flex",
              justifyContent: "space-between",
            }}
          >
            <span>{SECTION_LABELS[kind] ?? kind}</span>
            <span style={{ fontFamily: "JetBrains Mono, monospace" }}>{items.length}</span>
          </div>
          {items.map(({ suggestion: s, globalIndex }) => (
            <div
              key={s.id}
              className={`suggestion ${globalIndex === activeIndex ? "active" : ""}`}
              role="option"
              aria-selected={globalIndex === activeIndex}
              data-testid={`suggestion-${globalIndex}`}
              data-kind={s.kind}
              onMouseEnter={() => onHover(globalIndex)}
              onMouseDown={(e) => {
                e.preventDefault();
                onPick(s);
              }}
            >
              <span className="icon" aria-hidden="true">
                {s.icon ?? "·"}
              </span>
              <span className="label">{s.label}</span>
              {s.signature && (
                <span className="detail" style={{ color: "var(--violet-2)" }}>
                  {s.signature}
                </span>
              )}
              {!s.signature && s.detail && <span className="detail">{s.detail}</span>}
            </div>
          ))}
        </div>
      ))}

      <div
        style={{
          padding: "8px 14px",
          marginTop: 4,
          background: "rgba(0, 0, 0, 0.25)",
          borderTop: "1px solid var(--border)",
          display: "flex",
          alignItems: "center",
          gap: 14,
          fontSize: 10.5,
          color: "var(--fg-faint)",
          fontFamily: "JetBrains Mono, monospace",
          borderRadius: "0 0 8px 8px",
        }}
      >
        <span>
          <span className="kbd" style={{ padding: "1px 5px", border: "1px solid var(--border)", borderRadius: 3, marginRight: 4 }}>
            ↑↓
          </span>
          navigate
        </span>
        <span>
          <span className="kbd" style={{ padding: "1px 5px", border: "1px solid var(--border)", borderRadius: 3, marginRight: 4 }}>
            ⏎
          </span>
          insert
        </span>
        <span>
          <span className="kbd" style={{ padding: "1px 5px", border: "1px solid var(--border)", borderRadius: 3, marginRight: 4 }}>
            ⇥
          </span>
          complete
        </span>
        <span>
          <span className="kbd" style={{ padding: "1px 5px", border: "1px solid var(--border)", borderRadius: 3, marginRight: 4 }}>
            ⎋
          </span>
          cerrar
        </span>
        <span style={{ marginLeft: "auto", color: "var(--fg-dim)" }}>
          {suggestions.length} matches
        </span>
      </div>
    </div>
  );
}
