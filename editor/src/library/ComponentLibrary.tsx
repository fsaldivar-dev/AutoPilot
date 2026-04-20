import { selectCurrentProject, useStore } from "../state/store";

export function ComponentLibrary() {
  const project = useStore(selectCurrentProject);
  if (!project) return null;

  if (project.components.length === 0) {
    return (
      <div>
        <div className="section-title">Componentes</div>
        <div className="empty-state" style={{ padding: "16px 0", fontSize: 11 }}>
          Sin componentes todavia. Selecciona 2+ bloques en el canvas y presiona
          "Agrupar".
        </div>
      </div>
    );
  }

  return (
    <div data-testid="component-library">
      <div className="section-title">Componentes</div>
      {project.components.map((c) => (
        <div
          key={c.id}
          className="component-card"
          draggable
          data-testid={`component-${c.id}`}
          data-component-id={c.id}
        >
          <div className="name">🧩 {c.name}</div>
          <div className="sig">
            ({c.signature.map((p) => `${p.name}`).join(", ")})
            {c.returnType ? ` → ${c.returnType}` : ""}
          </div>
          <div className="usage">
            {c.usageCount}× usado · {c.body.length} pasos
          </div>
        </div>
      ))}
    </div>
  );
}
