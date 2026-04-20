import { selectCurrentFlow, useStore } from "../state/store";

export function Timeline() {
  const flow = useStore(selectCurrentFlow);
  if (!flow) return null;

  const events = flow.blocks.filter((b) => b.meta.status === "ok" || b.meta.status === "err");

  return (
    <div className="timeline" data-testid="timeline">
      <div className="section-title">Timeline</div>
      {events.length === 0 ? (
        <div style={{ fontSize: 11, color: "var(--text-mute)" }}>
          Sin eventos ejecutados
        </div>
      ) : (
        events.map((b) => (
          <div key={b.id} className="timeline-event" data-testid={`event-${b.id}`}>
            <span className="ts">
              {b.meta.ranAt
                ? new Date(b.meta.ranAt).toLocaleTimeString("es-MX", { hour12: false })
                : "--:--:--"}
            </span>
            <span className={`kind ${b.meta.status === "err" ? "err" : ""}`}>
              {firstWord(b.command ?? "")}
            </span>
            <span style={{ flex: 1, color: "var(--text-dim)" }}>
              {rest(b.command ?? "")}
            </span>
            <span style={{ color: b.meta.status === "err" ? "var(--coral)" : "var(--mint)" }}>
              {b.meta.status === "err" ? "✗" : "✓"} {b.meta.ms ?? 0}ms
            </span>
          </div>
        ))
      )}
    </div>
  );
}

function firstWord(s: string): string {
  return s.split(/\s+/)[0] || "";
}

function rest(s: string): string {
  return s.split(/\s+/).slice(1).join(" ");
}
