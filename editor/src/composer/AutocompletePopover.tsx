import type { Suggestion } from "../domain/types";

interface Props {
  suggestions: Suggestion[];
  activeIndex: number;
  onPick: (s: Suggestion) => void;
  onHover: (index: number) => void;
}

export function AutocompletePopover({
  suggestions,
  activeIndex,
  onPick,
  onHover,
}: Props) {
  if (suggestions.length === 0) return null;

  return (
    <div className="autocomplete-popover" role="listbox" data-testid="autocomplete-popover">
      {suggestions.map((s, i) => (
        <div
          key={s.id}
          className={`suggestion ${i === activeIndex ? "active" : ""}`}
          role="option"
          aria-selected={i === activeIndex}
          data-testid={`suggestion-${i}`}
          data-kind={s.kind}
          onMouseEnter={() => onHover(i)}
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
            <span className="detail" style={{ fontFamily: "JetBrains Mono, monospace" }}>
              {s.signature}
            </span>
          )}
          {!s.signature && s.detail && <span className="detail">{s.detail}</span>}
        </div>
      ))}
    </div>
  );
}
