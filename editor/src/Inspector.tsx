import { useState, useMemo } from "react";

interface AXElement {
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
  { label: "scroll", icon: "📜", cmd: (el: string) => `scroll "${el}" down` },
];

function parseFrame(frame: string): { x: number; y: number; w: number; h: number } | null {
  // Format: [x,y widthxheight]
  const m = frame.match(/\[(\d+),(\d+)\s+(\d+)x(\d+)\]/);
  if (!m) return null;
  return { x: +m[1], y: +m[2], w: +m[3], h: +m[4] };
}

function roleColor(role: string): string {
  if (role.includes("Button")) return "#FF6B6B";
  if (role.includes("TextField") || role.includes("TextArea")) return "#E5C07B";
  if (role.includes("StaticText")) return "#98C379";
  if (role.includes("Image")) return "#C678DD";
  if (role.includes("Group") || role.includes("Tab")) return "#61AFEF";
  if (role.includes("Heading")) return "#D19A66";
  return "#565F89";
}

interface InspectorProps {
  elements: AXElement[];
  onInsert: (cmd: string) => void;
  onClose: () => void;
}

export default function Inspector({ elements, onInsert, onClose }: InspectorProps) {
  const [selected, setSelected] = useState<ParsedElement | null>(null);
  const [hovered, setHovered] = useState<ParsedElement | null>(null);
  const [filter, setFilter] = useState("");

  // Parse elements with frames
  const parsed = useMemo(() => {
    const result: ParsedElement[] = [];
    for (const el of elements) {
      const f = parseFrame(el.frame);
      if (f && f.w > 0 && f.h > 0) {
        result.push({ ...el, ...f });
      }
    }
    return result;
  }, [elements]);

  // Filter
  const filtered = useMemo(() => {
    if (!filter) return parsed;
    const q = filter.toLowerCase();
    return parsed.filter(
      (el) =>
        el.display.toLowerCase().includes(q) ||
        el.role.toLowerCase().includes(q) ||
        el.id.toLowerCase().includes(q)
    );
  }, [parsed, filter]);

  // Calculate scale to fit in panel
  const layout = useMemo(() => {
    if (parsed.length === 0) return { scale: 1, offsetX: 0, offsetY: 0, viewW: 400, viewH: 700 };
    let maxX = 0, maxY = 0;
    for (const el of parsed) {
      maxX = Math.max(maxX, el.x + el.w);
      maxY = Math.max(maxY, el.y + el.h);
    }
    const panelW = 380;
    const panelH = 600;
    const scale = Math.min(panelW / maxX, panelH / maxY) * 0.95;
    const offsetX = (panelW - maxX * scale) / 2;
    const offsetY = 8;
    return { scale, offsetX, offsetY, viewW: maxX, viewH: maxY };
  }, [parsed]);

  const active = hovered || selected;

  return (
    <div className="inspector">
      <div className="inspector-header">
        <span>Inspector ({parsed.length})</span>
        <div className="inspector-controls">
          <input
            className="inspector-search"
            placeholder="Buscar..."
            value={filter}
            onChange={(e) => setFilter(e.target.value)}
          />
          <button className="btn-close" onClick={onClose}>×</button>
        </div>
      </div>

      {/* Visual Layout */}
      <div className="inspector-canvas">
        <svg width="100%" height="100%" viewBox={`0 0 ${layout.viewW} ${layout.viewH}`}>
          {/* Background */}
          <rect x="0" y="0" width={layout.viewW} height={layout.viewH} fill="#1A1B26" rx="12" />

          {/* Elements */}
          {filtered.map((el, i) => {
            const isActive = active === el;
            const isSelected = selected === el;
            const color = roleColor(el.role);
            const opacity = filter && !filtered.includes(el) ? 0.1 : isActive ? 0.4 : 0.15;

            return (
              <g key={i}
                onClick={(e) => { e.stopPropagation(); setSelected(isSelected ? null : el); }}
                onMouseEnter={() => setHovered(el)}
                onMouseLeave={() => setHovered(null)}
                style={{ cursor: "pointer" }}>
                <rect
                  x={el.x} y={el.y} width={el.w} height={el.h}
                  fill={color} fillOpacity={opacity}
                  stroke={color} strokeOpacity={isActive ? 0.9 : 0.3}
                  strokeWidth={isActive ? 2 : 0.5}
                  rx="3"
                />
                {/* Label if element is big enough */}
                {el.w > 30 && el.h > 12 && (
                  <text
                    x={el.x + el.w / 2} y={el.y + el.h / 2 + 4}
                    textAnchor="middle" fill={color} fillOpacity={isActive ? 1 : 0.7}
                    fontSize={Math.min(11, el.h * 0.6, el.w * 0.15)}
                    fontFamily="SF Mono, monospace" fontWeight="500">
                    {el.display.length > 20 ? el.display.slice(0, 18) + "..." : el.display}
                  </text>
                )}
              </g>
            );
          })}
        </svg>
      </div>

      {/* Detail + Actions */}
      {active && (
        <div className="inspector-detail">
          <div className="detail-info">
            <span className="detail-role" style={{ color: roleColor(active.role) }}>
              {active.role.replace("AX", "")}
            </span>
            {active.display && (
              <span className="detail-label">"{active.display}"</span>
            )}
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
