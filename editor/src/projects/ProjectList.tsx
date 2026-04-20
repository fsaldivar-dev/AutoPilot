import { useStore } from "../state/store";

interface Props {
  onNewProject: () => void;
}

export function ProjectList({ onNewProject }: Props) {
  const projects = useStore((s) => s.projects);
  const currentId = useStore((s) => s.currentProjectId);
  const setCurrent = useStore((s) => s.setCurrentProject);

  return (
    <div data-testid="project-list">
      <div className="section-title" style={{ display: "flex", alignItems: "center", justifyContent: "space-between" }}>
        <span>Proyectos</span>
        <button className="btn btn-icon" onClick={onNewProject} aria-label="Nuevo proyecto" data-testid="new-project-btn">
          +
        </button>
      </div>
      {projects.length === 0 ? (
        <div className="empty-state" style={{ padding: "20px 0" }}>
          <div>Sin proyectos</div>
          <div className="hint">Crea uno para empezar</div>
        </div>
      ) : (
        projects.map((p) => (
          <div
            key={p.id}
            data-testid={`project-${p.id}`}
            className={`project-card ${currentId === p.id ? "active" : ""}`}
            onClick={() => setCurrent(p.id)}
          >
            <div className="name">{p.name}</div>
            <div className="meta">
              {p.platform} · {p.flows.length} flows · {p.components.length} componentes
            </div>
          </div>
        ))
      )}
    </div>
  );
}
