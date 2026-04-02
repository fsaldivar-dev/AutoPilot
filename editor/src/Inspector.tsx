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

  // Find the content area offset (largest AXGroup = simulator content)
  // AX frames include macOS window chrome, screenshot is only iOS content
  const viewport = useMemo(() => {
    if (parsed.length === 0) return { offsetX: 0, offsetY: 0, width: 430, height: 932 };

    // Find the largest element by area — that's the simulator content group
    let contentEl = parsed[0];
    let maxArea = 0;
    for (const el of parsed) {
      const area = el.w * el.h;
      if (area > maxArea) {
        maxArea = area;
        contentEl = el;
      }
    }

    return {
      offsetX: contentEl.x,
      offsetY: contentEl.y,
      width: contentEl.w,
      height: contentEl.h,
    };
  }, [parsed]);

  // Adjust elements to be relative to the content area
  // Sort by area descending so small elements (buttons) render ON TOP of large ones (groups)
  const adjusted = useMemo(() => {
    return parsed
      .filter(el => el.x >= viewport.offsetX && el.y >= viewport.offsetY)
      .map(el => ({
        ...el,
        x: el.x - viewport.offsetX,
        y: el.y - viewport.offsetY,
      }))
      .sort((a, b) => (b.w * b.h) - (a.w * a.h));
  }, [parsed, viewport]);

  const active = hovered || selected;

  return (
    <div className="inspector">
      <div className="inspector-header">
        <span>Inspector ({parsed.length})</span>
        <button className="btn-close" onClick={onClose}>×</button>
      </div>

      <div className="inspector-canvas" ref={containerRef}>
        <div className="canvas-viewport" style={{ aspectRatio: `${viewport.width} / ${viewport.height}` }}>
          {/* Real screenshot as background */}
          {screenshot && (
            <img src={screenshot} alt="Simulator" className="canvas-screenshot" draggable={false} />
          )}

          {/* Overlay hitboxes — coordinates adjusted to content area */}
          <svg className="canvas-overlay" viewBox={`0 0 ${viewport.width} ${viewport.height}`} preserveAspectRatio="none">
            {adjusted.map((el, i) => {
              const isHovered = hovered?.display === el.display && hovered?.frame === el.frame;
              const isSelected = selected?.display === el.display && selected?.frame === el.frame;
              const color = roleColor(el.role);

              return (
                <rect
                  key={i}
                  x={el.x} y={el.y} width={el.w} height={el.h}
                  fill={isHovered || isSelected ? color : "transparent"}
                  fillOpacity={isSelected ? 0.25 : isHovered ? 0.15 : 0}
                  stroke={isHovered || isSelected ? color : "transparent"}
                  strokeWidth={isSelected ? 2 : isHovered ? 1 : 0}
                  rx="3"
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
                left: `${(hovered.x / viewport.width) * 100}%`,
                top: `${Math.max(0, (hovered.y / viewport.height) * 100 - 3)}%`,
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
