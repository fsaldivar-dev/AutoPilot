// Bidirectional sync between Zustand store and SQLite, debounced.

import { useStore } from "../state/store";
import * as db from "./db";
import type { Project } from "../domain/types";
import {
  componentToRow,
  envVarToRow,
  flowToRow,
  projectToRow,
} from "../domain/serializers";

let saveTimer: ReturnType<typeof setTimeout> | undefined;
let lastSnapshot: string = "";

// JSON de la última fila persistida por entidad (`proj:<id>`, `flow:<id>`,
// `comp:<id>`, `env:<projectId>/<scope>/<key>`). Permite que el autosave
// upserte solo lo que cambió en lugar de reescribir todo cada vez.
const savedRows = new Map<string, string>();

function entityRows(p: Project): Array<[string, string, () => Promise<void>]> {
  return [
    [`proj:${p.id}`, JSON.stringify(projectToRow(p)), () => db.upsertProject(p)],
    ...p.flows.map(
      (f): [string, string, () => Promise<void>] => [
        `flow:${f.id}`,
        JSON.stringify(flowToRow(f)),
        () => db.upsertFlow(f),
      ]
    ),
    ...p.components.map(
      (c): [string, string, () => Promise<void>] => [
        `comp:${c.id}`,
        JSON.stringify(componentToRow(c)),
        () => db.upsertComponent(c),
      ]
    ),
    ...p.env.map(
      (e): [string, string, () => Promise<void>] => [
        `env:${e.projectId}/${e.scope}/${e.key}`,
        JSON.stringify(envVarToRow(e)),
        () => db.upsertEnvVar(e),
      ]
    ),
  ];
}

function primeSavedRows(projects: Project[]): void {
  savedRows.clear();
  for (const p of projects) {
    for (const [key, json] of entityRows(p)) savedRows.set(key, json);
  }
}

export async function hydrateFromDisk(): Promise<void> {
  try {
    const projects = await db.listProjects();
    if (!projects || projects.length === 0) return;
    const hydrated: Project[] = await Promise.all(
      projects.map(async (p) => {
        const [flows, components, env] = await Promise.all([
          db.listFlows(p.id).catch(() => []),
          db.listComponents(p.id).catch(() => []),
          db.listEnvVars(p.id).catch(() => []),
        ]);
        return { ...p, flows, components, env };
      })
    );
    useStore.getState().setProjects(hydrated);
    lastSnapshot = JSON.stringify(hydrated);
    primeSavedRows(hydrated);
  } catch {
    // Tauri not available (tests / web preview).
  }
}

export function startAutoSave(debounceMs = 500): () => void {
  // Subscribes to project changes in the store and debounces a DB write.
  const unsub = useStore.subscribe((state) => {
    const snapshot = JSON.stringify(state.projects);
    if (snapshot === lastSnapshot) return;
    lastSnapshot = snapshot;
    if (saveTimer) clearTimeout(saveTimer);
    saveTimer = setTimeout(() => {
      void saveAll(state.projects).catch(() => {});
    }, debounceMs);
  });
  return () => {
    unsub();
    if (saveTimer) clearTimeout(saveTimer);
  };
}

async function saveAll(projects: Project[]): Promise<void> {
  const seen = new Set<string>();
  for (const p of projects) {
    try {
      const ops: Array<Promise<void>> = [];
      for (const [key, json, upsert] of entityRows(p)) {
        seen.add(key);
        if (savedRows.get(key) === json) continue;
        // Registrar la fila como guardada solo si el upsert tuvo éxito.
        ops.push(upsert().then(() => void savedRows.set(key, json)));
      }
      await Promise.all(ops);
    } catch {
      // Tauri command may not be available in test environments.
    }
  }
  // Podar claves de entidades que ya no existen (borradas del store): si
  // reaparecen con el mismo contenido deben volver a upsertarse.
  for (const key of Array.from(savedRows.keys())) {
    if (!seen.has(key)) savedRows.delete(key);
  }
  useStore.getState().showToast?.("info", "Guardado");
  setTimeout(() => useStore.getState().dismissToast(), 800);
}
