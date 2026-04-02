import { useState, useMemo, useRef } from "react";

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

const ACTIONS = [
  { label: "tap", icon: "👆", cmd: (el: string) => `tap "${el}"` },
  { label: "doubleTap", icon: "👆👆", cmd: (el: string) => `doubleTap "${el}"` },
  { label: "longPress", icon: "✊", cmd: (el: string) => `longPress "${el}" 1` },
  { label: "type", icon: "⌨️", cmd: (el: string) => `type "${el}" "text"` },
  { label: "clear", icon: "🗑", cmd: (el: string) => `clear "${el}"` },
  { label: "waitFor", icon: "⏳", cmd: (el: string) => `waitFor "${el}" 10` },
  { label: "exists", icon: "❓", cmd: (el: string) => `exists "${el}"` },
];

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

interface InspectorProps {
  elements: AXElement[];
  screenshot: string;
  onInsert: (cmd: string) => void;
  onClose: () => void;
}

export default function Inspector({ elements, screenshot, onInsert, onClose }: InspectorProps) {
  const [selected, setSelected] = useState<ParsedElement | null>(null);
  const [hovered, setHovered] = useState<ParsedElement | null>(null);
  const containerRef = useRef<HTMLDivElement>(null);

  const parsed = useMemo(() => {
    const result: ParsedElement[] = [];
    for (const el of elements) {
      const f = parseFrame(el.frame);
      if (f && f.w > 2 && f.h > 2) {
        result.push({ ...el, ...f });
      }
    }
    return result;
  }, [elements]);

  // Simulator viewport bounds
  const bounds = useMemo(() => {
    if (parsed.length === 0) return { maxX: 430, maxY: 932 };
    let maxX = 0, maxY = 0;
    for (const el of parsed) {
      maxX = Math.max(maxX, el.x + el.w);
      maxY = Math.max(maxY, el.y + el.h);
    }
    return { maxX, maxY };
  }, [parsed]);

  const active = hovered || selected;

  return (
    <div className="inspector">
      <div className="inspector-header">
        <span>Inspector ({parsed.length})</span>
        <button className="btn-close" onClick={onClose}>×</button>
      </div>

      <div className="inspector-canvas" ref={containerRef}>
        <div className="canvas-viewport" style={{ aspectRatio: `${bounds.maxX} / ${bounds.maxY}` }}>
          {/* Real screenshot as background */}
          {screenshot && (
            <img src={screenshot} alt="Simulator" className="canvas-screenshot" draggable={false} />
          )}

          {/* Overlay hitboxes */}
          <svg className="canvas-overlay" viewBox={`0 0 ${bounds.maxX} ${bounds.maxY}`}>
            {parsed.map((el, i) => {
              const isHovered = hovered === el;
              const isSelected = selected === el;
              const color = roleColor(el.role);

              return (
                <rect
                  key={i}
                  x={el.x} y={el.y} width={el.w} height={el.h}
                  fill={isHovered || isSelected ? color : "transparent"}
                  fillOpacity={isSelected ? 0.3 : isHovered ? 0.2 : 0}
                  stroke={isHovered || isSelected ? color : "transparent"}
                  strokeWidth={isSelected ? 2.5 : isHovered ? 1.5 : 0}
                  rx="4"
                  style={{ cursor: "pointer" }}
                  onClick={(e) => { e.stopPropagation(); setSelected(isSelected ? null : el); }}
                  onMouseEnter={() => setHovered(el)}
                  onMouseLeave={() => setHovered(null)}
                />
              );
            })}
          </svg>

          {/* Tooltip on hover */}
          {hovered && !selected && (
            <div className="canvas-tooltip"
              style={{
                left: `${(hovered.x / bounds.maxX) * 100}%`,
                top: `${(hovered.y / bounds.maxY) * 100 - 4}%`,
              }}>
              <span className="tooltip-role" style={{ color: roleColor(hovered.role) }}>
                {hovered.role.replace("AX", "")}
              </span>
              {hovered.display && <span className="tooltip-label">"{hovered.display}"</span>}
            </div>
          )}
        </div>
      </div>

      {/* Detail + Actions */}
      {active && (
        <div className="inspector-detail">
          <div className="detail-info">
            <span className="detail-role" style={{ color: roleColor(active.role) }}>
              {active.role.replace("AX", "")}
            </span>
            {active.display && <span className="detail-label">"{active.display}"</span>}
            {active.id && <span className="detail-id">id={active.id}</span>}
            <span className="detail-frame">{active.frame}</span>
          </div>
          {selected === active && (
            <div className="detail-actions">
              {ACTIONS.map((action) => (
                <button key={action.label} className="action-btn"
                  onClick={() => {
                    onInsert(action.cmd(active.display || active.id || active.role));
                    setSelected(null);
                  }}>
                  <span>{action.icon}</span> {action.label}
                </button>
              ))}
            </div>
          )}
        </div>
      )}
    </div>
  );
}
