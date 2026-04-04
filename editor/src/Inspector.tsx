import { useState, useMemo } from "react";

export interface AXElement {
  role: string;
  label: string;
  id: string;
  value: string;
  frame: string;
  depth: number;
  display: string;
}

interface ParsedElement extends AXElement {
  x: number;
  y: number;
  w: number;
  h: number;
}

// Actions use label[N] for duplicates, plain label otherwise
function makeActions(label: string, suffix: string) {
  const ref = suffix ? `${label}${suffix}` : label;
  return [
    { label: "tap", icon: "👆", cmd: `tap "${ref}"` },
    { label: "doubleTap", icon: "👆👆", cmd: `doubleTap "${ref}"` },
    { label: "longPress", icon: "✊", cmd: `longPress "${ref}" 1` },
    { label: "type", icon: "⌨️", cmd: `type "${ref}" "text"` },
    { label: "clear", icon: "🗑", cmd: `clear "${ref}"` },
    { label: "scroll", icon: "📜", cmd: `scroll "${ref}" down` },
    { label: "waitFor", icon: "⏳", cmd: `waitFor "${ref}" 10` },
    { label: "exists", icon: "❓", cmd: `exists "${ref}"` },
  ];
}

function parseFrame(frame: string): { x: number; y: number; w: number; h: number } | null {
  const m = frame.match(/\[(\d+),(\d+)\s+(\d+)x(\d+)\]/);
  if (!m) return null;
  return { x: +m[1], y: +m[2], w: +m[3], h: +m[4] };
}

function roleColor(role: string): string {
  if (role.includes("Button")) return "#FF6B6B";
  if (role.includes("TextField") || role.includes("TextArea")) return "#E5C07B";
  if (role.includes("StaticText")) return "#98C379";
  if (role.includes("Image")) return "#C678DD";
  if (role.includes("Heading")) return "#D19A66";
  return "#61AFEF";
}

function roleIcon(role: string): string {
  if (role.includes("Button")) return "🔘";
  if (role.includes("TextField") || role.includes("TextArea")) return "📝";
  if (role.includes("StaticText")) return "📄";
  if (role.includes("Image")) return "🖼";
  if (role.includes("Group")) return "📦";
  if (role.includes("Heading")) return "🏷";
  if (role.includes("Tab")) return "📑";
  if (role.includes("CheckBox")) return "☑️";
  return "◻️";
}

interface IndexedElement {
  index: number;
  role: string;
  label: string;
  frame: string;
}

interface InspectorProps {
  elements: AXElement[];
  indexed: IndexedElement[];
  screenshot: string;
  onInsert: (cmd: string) => void;
  onClose: () => void;
}

export default function Inspector({ elements, indexed, screenshot, onInsert, onClose }: InspectorProps) {
  const [tab, setTab] = useState<"preview" | "tree">("preview");
  const [selected, setSelected] = useState<ParsedElement | null>(null);
  const [hovered, setHovered] = useState<ParsedElement | null>(null);
  const [treeSelected, setTreeSelected] = useState<AXElement | null>(null);

  const parsed = useMemo(() => {
    const result: ParsedElement[] = [];
    for (const el of elements) {
      const f = parseFrame(el.frame);
      if (f && f.w > 2 && f.h > 2) result.push({ ...el, ...f });
    }
    return result;
  }, [elements]);

  const viewport = useMemo(() => {
    if (parsed.length === 0) return { offsetX: 0, offsetY: 0, width: 430, height: 932 };
    let contentEl = parsed[0];
    let maxArea = 0;
    for (const el of parsed) {
      const area = el.w * el.h;
      if (area > maxArea) { maxArea = area; contentEl = el; }
    }
    return { offsetX: contentEl.x, offsetY: contentEl.y, width: contentEl.w, height: contentEl.h };
  }, [parsed]);

  const adjusted = useMemo(() => {
    return parsed
      .filter(el => el.x >= viewport.offsetX && el.y >= viewport.offsetY)
      .map(el => ({ ...el, x: el.x - viewport.offsetX, y: el.y - viewport.offsetY }))
      .sort((a, b) => (b.w * b.h) - (a.w * a.h));
  }, [parsed, viewport]);

  // Find $N index for an element by matching label + frame
  const findIndex = (el: { display?: string; label?: string; frame?: string; role?: string }): number | null => {
    const label = el.display || el.label || "";
    const frame = el.frame || "";
    for (const idx of indexed) {
      if (idx.label === label && idx.frame === frame) return idx.index;
      if (idx.label === label && idx.role === el.role?.replace("AX", "")) return idx.index;
    }
    // Fallback: match by label only
    for (const idx of indexed) {
      if (idx.label === label) return idx.index;
    }
    return null;
  };

  const active = hovered || selected;
  const activeElement = tab === "preview" ? active : treeSelected;
  const activeDisplay = activeElement?.display || activeElement?.id || activeElement?.role || "";
  const activeIndex = activeElement ? findIndex(activeElement) : null;

  return (
    <div className="inspector">
      <div className="inspector-header">
        <div className="inspector-tabs">
          <button className={`tab ${tab === "preview" ? "active" : ""}`} onClick={() => setTab("preview")}>
            Preview
          </button>
          <button className={`tab ${tab === "tree" ? "active" : ""}`} onClick={() => setTab("tree")}>
            Tree
          </button>
        </div>
        <button className="btn-close" onClick={onClose}>×</button>
      </div>

      {/* Preview Tab */}
      {tab === "preview" && (
        <div className="inspector-canvas">
          <div className="canvas-viewport" style={{ aspectRatio: `${viewport.width} / ${viewport.height}` }}>
            {screenshot && (
              <img src={screenshot} alt="Simulator" className="canvas-screenshot" draggable={false} />
            )}
            <svg className="canvas-overlay" viewBox={`0 0 ${viewport.width} ${viewport.height}`} preserveAspectRatio="none">
              {adjusted.map((el, i) => {
                const isHov = hovered?.display === el.display && hovered?.frame === el.frame;
                const isSel = selected?.display === el.display && selected?.frame === el.frame;
                const color = roleColor(el.role);
                return (
                  <rect key={i} x={el.x} y={el.y} width={el.w} height={el.h}
                    fill={isHov || isSel ? color : "transparent"}
                    fillOpacity={isSel ? 0.25 : isHov ? 0.15 : 0}
                    stroke={isHov || isSel ? color : "transparent"}
                    strokeWidth={isSel ? 2 : isHov ? 1 : 0}
                    rx="3" style={{ cursor: "pointer" }}
                    onClick={(e) => { e.stopPropagation(); setSelected(isSel ? null : el); }}
                    onMouseEnter={() => setHovered(el)}
                    onMouseLeave={() => setHovered(null)}
                  />
                );
              })}
            </svg>
            {hovered && !selected && (() => {
              const idx = findIndex(hovered);
              return (
                <div className="canvas-tooltip" style={{
                  left: `${(hovered.x / viewport.width) * 100}%`,
                  top: `${Math.max(0, (hovered.y / viewport.height) * 100 - 3)}%`,
                }}>
                  {idx !== null && <span className="tooltip-index">${idx}</span>}
                  <span className="tooltip-role" style={{ color: roleColor(hovered.role) }}>
                    {hovered.role.replace("AX", "")}
                  </span>
                  {hovered.display && <span className="tooltip-label">"{hovered.display}"</span>}
                </div>
              );
            })()}
          </div>
        </div>
      )}

      {/* Tree Tab */}
      {tab === "tree" && (
        <div className="inspector-tree">
          {elements.map((el, i) => {
            const idx = findIndex(el);
            return (
              <div key={i}
                className={`tree-row ${treeSelected === el ? "selected" : ""}`}
                style={{ paddingLeft: `${8 + el.depth * 14}px` }}
                onClick={() => setTreeSelected(treeSelected === el ? null : el)}>
                {idx !== null && <span className="tree-index">${idx}</span>}
                <span className="tree-icon">{roleIcon(el.role)}</span>
                <span className="tree-role" style={{ color: roleColor(el.role) }}>
                  {el.role.replace("AX", "")}
                </span>
                {el.display && el.display !== el.role && (
                  <span className="tree-label">"{el.display}"</span>
                )}
                {el.frame && <span className="tree-frame">{el.frame}</span>}
              </div>
            );
          })}
        </div>
      )}

      {/* Actions bar */}
      {activeElement && (() => {
        // Check if label has duplicates → add [N] suffix
        const dupes = indexed.filter(e => e.label === activeDisplay);
        let suffix = "";
        if (dupes.length > 1 && activeIndex !== null) {
          const pos = dupes.findIndex(e => e.index === activeIndex);
          if (pos >= 0) suffix = `[${pos + 1}]`;
        }
        const actions = makeActions(activeDisplay, suffix);
        return (
          <div className="inspector-actions">
            <div className="actions-info">
              {activeIndex !== null && <span className="actions-index">${activeIndex}</span>}
              <span style={{ color: roleColor(activeElement.role), fontWeight: 700, fontSize: 12 }}>
                {activeElement.role.replace("AX", "")}
              </span>
              {activeDisplay && <span className="actions-label">"{activeDisplay}"</span>}
            </div>
            <div className="actions-buttons">
              {actions.map((action) => (
                <button key={action.label} className="action-btn"
                  onClick={() => {
                    onInsert(action.cmd);
                    setSelected(null);
                    setTreeSelected(null);
                  }}>
                  <span>{action.icon}</span> {action.label}
                </button>
              ))}
            </div>
          </div>
        );
      })()}
    </div>
  );
}
