import { useState } from "react";
import { nanoid } from "nanoid";
import { useStore } from "../state/store";
import type { Platform } from "../domain/types";

interface Props {
  onClose: () => void;
}

export function NewProjectModal({ onClose }: Props) {
  const [name, setName] = useState("");
  const [platform, setPlatform] = useState<Platform>("ios");
  const addProject = useStore((s) => s.addProject);
  const setCurrentProject = useStore((s) => s.setCurrentProject);
  const setCurrentFlow = useStore((s) => s.setCurrentFlow);

  function create() {
    if (!name.trim()) return;
    const id = `prj_${nanoid(8)}`;
    const now = Date.now();
    const flowId = `flow_${nanoid(8)}`;
    addProject({
      id,
      name: name.trim(),
      platform,
      flows: [
        {
          id: flowId,
          projectId: id,
          name: "Happy path",
          blocks: [],
          updatedAt: now,
        },
      ],
      components: [],
      env: [],
      devices: [],
      createdAt: now,
      updatedAt: now,
    });
    setCurrentProject(id);
    setCurrentFlow(flowId);
    onClose();
  }

  return (
    <div className="modal-backdrop" onClick={onClose} data-testid="new-project-modal">
      <div className="modal" onClick={(e) => e.stopPropagation()}>
        <h2>Nuevo proyecto</h2>
        <div className="field">
          <label>Nombre</label>
          <input
            autoFocus
            value={name}
            onChange={(e) => setName(e.target.value)}
            placeholder="Banco Atlas"
            data-testid="new-project-name"
            onKeyDown={(e) => {
              if (e.key === "Enter") create();
            }}
          />
        </div>
        <div className="field">
          <label>Plataforma</label>
          <select value={platform} onChange={(e) => setPlatform(e.target.value as Platform)}>
            <option value="ios">iOS</option>
            <option value="android">Android</option>
            <option value="both">Ambas</option>
          </select>
        </div>
        <div className="modal-actions">
          <button className="btn" onClick={onClose}>
            Cancelar
          </button>
          <button className="btn btn-primary" onClick={create} data-testid="new-project-create">
            Crear proyecto
          </button>
        </div>
      </div>
    </div>
  );
}
