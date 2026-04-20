// Bidirectional sync between Zustand store and SQLite, debounced.

import { useStore } from "../state/store";
import * as db from "./db";
import type { Project } from "../domain/types";

let saveTimer: ReturnType<typeof setTimeout> | undefined;
let lastSnapshot: string = "";

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
  for (const p of projects) {
    try {
      await db.upsertProject(p);
      await Promise.all(p.flows.map((f) => db.upsertFlow(f)));
      await Promise.all(p.components.map((c) => db.upsertComponent(c)));
      await Promise.all(p.env.map((e) => db.upsertEnvVar(e)));
    } catch {
      // Tauri command may not be available in test environments.
    }
  }
  useStore.getState().showToast?.("info", "Guardado");
  setTimeout(() => useStore.getState().dismissToast(), 800);
}
