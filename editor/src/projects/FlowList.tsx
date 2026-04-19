import { nanoid } from "nanoid";
import { selectCurrentProject, useStore } from "../state/store";

export function FlowList() {
  const project = useStore(selectCurrentProject);
  const currentFlowId = useStore((s) => s.currentFlowId);
  const setCurrentFlow = useStore((s) => s.setCurrentFlow);
  const addFlow = useStore((s) => s.addFlow);

  if (!project) return null;

  function newFlow() {
    if (!project) return;
    const id = `flow_${nanoid(8)}`;
    addFlow(project.id, {
      id,
      projectId: project.id,
      name: `Flow ${project.flows.length + 1}`,
      blocks: [],
      updatedAt: Date.now(),
    });
    setCurrentFlow(id);
  }

  return (
    <div>
      <div className="section-title" style={{ display: "flex", alignItems: "center", justifyContent: "space-between" }}>
        <span>Flows</span>
        <button className="btn btn-icon" onClick={newFlow} aria-label="Nuevo flow" data-testid="new-flow-btn">
          +
        </button>
      </div>
      {project.flows.map((f) => (
        <div
          key={f.id}
          data-testid={`flow-${f.id}`}
          className={`flow-item ${currentFlowId === f.id ? "active" : ""}`}
          onClick={() => setCurrentFlow(f.id)}
        >
          {f.name}{" "}
          <span style={{ color: "var(--text-mute)", fontSize: 10 }}>
            · {f.blocks.length} bloques
          </span>
        </div>
      ))}
    </div>
  );
}
