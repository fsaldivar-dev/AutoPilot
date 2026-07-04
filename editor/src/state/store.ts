// AutoPilot Composer — Zustand store.
// Slices: project, composer (blocks), executor (sessions), ui.

import { create } from "zustand";
import type {
  Block,
  Component,
  EnvVar,
  Flow,
  IndexedElement,
  Platform,
  Predicate,
  Project,
  RepeatMode,
  Suggestion,
} from "../domain/types";
import {
  insertIntoSlot,
  moveBlockTo,
  moveWithinSlot,
  removeFromSlot,
  updateBlockById,
  type DropTarget,
} from "./blockTree";

interface ProjectSlice {
  projects: Project[];
  currentProjectId?: string;
  currentFlowId?: string;
  setProjects: (p: Project[]) => void;
  addProject: (p: Project) => void;
  updateProject: (id: string, patch: Partial<Project>) => void;
  removeProject: (id: string) => void;
  setCurrentProject: (id: string | undefined) => void;
  setCurrentFlow: (id: string | undefined) => void;
  addFlow: (projectId: string, flow: Flow) => void;
  updateFlow: (flowId: string, patch: Partial<Flow>) => void;
  removeFlow: (flowId: string) => void;
  addComponent: (projectId: string, c: Component) => void;
  incrementComponentUsage: (projectId: string, componentId: string) => void;
  upsertEnvVar: (projectId: string, ev: EnvVar) => void;
  removeEnvVar: (projectId: string, scope: string, key: string) => void;
}

interface ComposerSlice {
  selectedBlockIds: string[];
  setSelectedBlocks: (ids: string[]) => void;
  appendBlock: (flowId: string, block: Block) => void;
  updateBlock: (flowId: string, blockId: string, patch: Partial<Block>) => void;
  removeBlock: (flowId: string, blockId: string) => void;
  moveBlock: (flowId: string, blockId: string, toIndex: number) => void;

  // Acciones jerárquicas (Fase 1.1) — operan sobre `slots` anidados.
  addChildBlock: (flowId: string, parentId: string, slot: number, block: Block) => void;
  removeChildBlock: (flowId: string, parentId: string, slot: number, blockId: string) => void;
  moveChildBlock: (
    flowId: string, parentId: string, slot: number, blockId: string, toIndex: number
  ) => void;
  // Drag & drop (#178): mueve un bloque a cualquier contenedor (raíz o slot).
  moveBlockToTarget: (flowId: string, blockId: string, dest: DropTarget) => void;
  updatePredicate: (flowId: string, blockId: string, predicate: Predicate) => void;
  updateRepeat: (flowId: string, blockId: string, repeat: RepeatMode) => void;
}

interface ExecutorSlice {
  sessionId?: string;
  sessionPlatform?: Platform;
  // Plataforma seleccionada en el toggle iOS/Android del toolbar. Vive en el
  // store (no en AppShell) para que consumidores fuera del árbol React — el
  // CompletionProvider de Monaco (#186) — lean la misma fuente.
  uiPlatform: Platform;
  setUiPlatform: (p: Platform) => void;
  running: boolean;
  elements: IndexedElement[];
  recentBlocks: Block[];
  autoRefresh: boolean;
  detectedApp: { name: string; bundle: string } | null;
  setSession: (id: string | undefined, platform?: Platform) => void;
  setRunning: (r: boolean) => void;
  setElements: (els: IndexedElement[]) => void;
  // Contador monotónico que incrementa cada vez que se ejecuta un comando
  // que podría haber mutado la UI. DevicePreview suscribe a este valor para
  // disparar un refresh reactivo (mirror fluido del simulator).
  refreshTick: number;
  bumpRefreshTick: () => void;
  pushRecent: (block: Block) => void;
  setAutoRefresh: (v: boolean) => void;
  setDetectedApp: (app: { name: string; bundle: string } | null) => void;
}

interface UiSlice {
  autocompleteOpen: boolean;
  autocompleteSuggestions: Suggestion[];
  autocompleteInput: string;
  autocompleteCursor: number;
  toast?: { level: "info" | "ok" | "err"; text: string };
  viewMode: "blocks" | "code";
  setAutocompleteOpen: (open: boolean) => void;
  setAutocompleteInput: (input: string, cursor: number) => void;
  setAutocompleteSuggestions: (s: Suggestion[]) => void;
  showToast: (level: "info" | "ok" | "err", text: string) => void;
  dismissToast: () => void;
  setViewMode: (mode: "blocks" | "code") => void;
}

export type Store = ProjectSlice & ComposerSlice & ExecutorSlice & UiSlice;

export const useStore = create<Store>((set) => ({
  // project
  projects: [],
  currentProjectId: undefined,
  currentFlowId: undefined,
  setProjects: (projects) => set({ projects }),
  addProject: (p) => set((s) => ({ projects: [...s.projects, p] })),
  updateProject: (id, patch) =>
    set((s) => ({
      projects: s.projects.map((pr) => (pr.id === id ? { ...pr, ...patch } : pr)),
    })),
  removeProject: (id) =>
    set((s) => ({
      projects: s.projects.filter((pr) => pr.id !== id),
      currentProjectId: s.currentProjectId === id ? undefined : s.currentProjectId,
    })),
  setCurrentProject: (id) => set({ currentProjectId: id, currentFlowId: undefined }),
  setCurrentFlow: (id) => set({ currentFlowId: id }),

  addFlow: (projectId, flow) =>
    set((s) => ({
      projects: s.projects.map((p) =>
        p.id === projectId ? { ...p, flows: [...p.flows, flow] } : p
      ),
    })),

  updateFlow: (flowId, patch) =>
    set((s) => ({
      projects: s.projects.map((p) => ({
        ...p,
        flows: p.flows.map((f) => (f.id === flowId ? { ...f, ...patch } : f)),
      })),
    })),

  removeFlow: (flowId) =>
    set((s) => ({
      projects: s.projects.map((p) => ({
        ...p,
        flows: p.flows.filter((f) => f.id !== flowId),
      })),
    })),

  addComponent: (projectId, c) =>
    set((s) => ({
      projects: s.projects.map((p) =>
        p.id === projectId ? { ...p, components: [...p.components, c] } : p
      ),
    })),

  incrementComponentUsage: (projectId, componentId) =>
    set((s) => ({
      projects: s.projects.map((p) =>
        p.id === projectId
          ? {
              ...p,
              components: p.components.map((c) =>
                c.id === componentId ? { ...c, usageCount: c.usageCount + 1 } : c
              ),
            }
          : p
      ),
    })),

  upsertEnvVar: (projectId, ev) =>
    set((s) => ({
      projects: s.projects.map((p) => {
        if (p.id !== projectId) return p;
        const without = p.env.filter(
          (e) => !(e.scope === ev.scope && e.key === ev.key)
        );
        return { ...p, env: [...without, ev] };
      }),
    })),

  removeEnvVar: (projectId, scope, key) =>
    set((s) => ({
      projects: s.projects.map((p) =>
        p.id === projectId
          ? { ...p, env: p.env.filter((e) => !(e.scope === scope && e.key === key)) }
          : p
      ),
    })),

  // composer
  selectedBlockIds: [],
  setSelectedBlocks: (ids) => set({ selectedBlockIds: ids }),

  appendBlock: (flowId, block) =>
    set((s) => ({
      projects: s.projects.map((p) => ({
        ...p,
        flows: p.flows.map((f) =>
          f.id === flowId
            ? {
                ...f,
                blocks: [...f.blocks, block],
                updatedAt: Date.now(),
              }
            : f
        ),
      })),
    })),

  updateBlock: (flowId, blockId, patch) =>
    set((s) => ({
      projects: s.projects.map((p) => ({
        ...p,
        flows: p.flows.map((f) =>
          f.id === flowId
            ? {
                ...f,
                blocks: f.blocks.map((b) =>
                  b.id === blockId ? { ...b, ...patch } : b
                ),
                updatedAt: Date.now(),
              }
            : f
        ),
      })),
    })),

  removeBlock: (flowId, blockId) =>
    set((s) => ({
      projects: s.projects.map((p) => ({
        ...p,
        flows: p.flows.map((f) =>
          f.id === flowId
            ? { ...f, blocks: f.blocks.filter((b) => b.id !== blockId) }
            : f
        ),
      })),
    })),

  moveBlock: (flowId, blockId, toIndex) =>
    set((s) => ({
      projects: s.projects.map((p) => ({
        ...p,
        flows: p.flows.map((f) => {
          if (f.id !== flowId) return f;
          const arr = [...f.blocks];
          const from = arr.findIndex((b) => b.id === blockId);
          if (from < 0) return f;
          const [item] = arr.splice(from, 1);
          arr.splice(toIndex, 0, item);
          return { ...f, blocks: arr, updatedAt: Date.now() };
        }),
      })),
    })),

  addChildBlock: (flowId, parentId, slot, block) =>
    set((s) => ({
      projects: s.projects.map((p) => ({
        ...p,
        flows: p.flows.map((f) =>
          f.id === flowId
            ? { ...f, blocks: insertIntoSlot(f.blocks, parentId, slot, block), updatedAt: Date.now() }
            : f
        ),
      })),
    })),

  removeChildBlock: (flowId, parentId, slot, blockId) =>
    set((s) => ({
      projects: s.projects.map((p) => ({
        ...p,
        flows: p.flows.map((f) =>
          f.id === flowId
            ? { ...f, blocks: removeFromSlot(f.blocks, parentId, slot, blockId), updatedAt: Date.now() }
            : f
        ),
      })),
    })),

  moveChildBlock: (flowId, parentId, slot, blockId, toIndex) =>
    set((s) => ({
      projects: s.projects.map((p) => ({
        ...p,
        flows: p.flows.map((f) =>
          f.id === flowId
            ? { ...f, blocks: moveWithinSlot(f.blocks, parentId, slot, blockId, toIndex), updatedAt: Date.now() }
            : f
        ),
      })),
    })),

  moveBlockToTarget: (flowId, blockId, dest) =>
    set((s) => ({
      projects: s.projects.map((p) => ({
        ...p,
        flows: p.flows.map((f) => {
          if (f.id !== flowId) return f;
          const blocks = moveBlockTo(f.blocks, blockId, dest);
          if (blocks === f.blocks) return f; // no-op — preserva identidad
          return { ...f, blocks, updatedAt: Date.now() };
        }),
      })),
    })),

  updatePredicate: (flowId, blockId, predicate) =>
    set((s) => ({
      projects: s.projects.map((p) => ({
        ...p,
        flows: p.flows.map((f) =>
          f.id === flowId
            ? {
                ...f,
                blocks: updateBlockById(f.blocks, blockId, (b) => ({ ...b, predicate })),
                updatedAt: Date.now(),
              }
            : f
        ),
      })),
    })),

  updateRepeat: (flowId, blockId, repeat) =>
    set((s) => ({
      projects: s.projects.map((p) => ({
        ...p,
        flows: p.flows.map((f) =>
          f.id === flowId
            ? {
                ...f,
                blocks: updateBlockById(f.blocks, blockId, (b) => ({ ...b, repeat })),
                updatedAt: Date.now(),
              }
            : f
        ),
      })),
    })),

  // executor
  sessionId: undefined,
  sessionPlatform: undefined,
  uiPlatform: "ios",
  setUiPlatform: (uiPlatform) => set({ uiPlatform }),
  running: false,
  elements: [],
  recentBlocks: [],
  autoRefresh: false,
  detectedApp: null,
  setSession: (id, platform) => set({ sessionId: id, sessionPlatform: platform }),
  setRunning: (r) => set({ running: r }),
  setElements: (elements) => set({ elements }),
  refreshTick: 0,
  bumpRefreshTick: () => set((s) => ({ refreshTick: s.refreshTick + 1 })),
  pushRecent: (block) =>
    set((s) => ({ recentBlocks: [block, ...s.recentBlocks].slice(0, 20) })),
  setAutoRefresh: (autoRefresh) => set({ autoRefresh }),
  setDetectedApp: (detectedApp) => set({ detectedApp }),

  // ui
  autocompleteOpen: false,
  autocompleteSuggestions: [],
  autocompleteInput: "",
  autocompleteCursor: 0,
  toast: undefined,
  setAutocompleteOpen: (autocompleteOpen) => set({ autocompleteOpen }),
  setAutocompleteInput: (autocompleteInput, autocompleteCursor) =>
    set({ autocompleteInput, autocompleteCursor }),
  setAutocompleteSuggestions: (autocompleteSuggestions) =>
    set({ autocompleteSuggestions }),
  showToast: (level, text) => set({ toast: { level, text } }),
  dismissToast: () => set({ toast: undefined }),
  viewMode: "blocks",
  setViewMode: (viewMode) => set({ viewMode }),
}));

// Selector helpers

export const selectCurrentProject = (s: Store): Project | undefined =>
  s.projects.find((p) => p.id === s.currentProjectId);

export const selectCurrentFlow = (s: Store): Flow | undefined => {
  const proj = selectCurrentProject(s);
  return proj?.flows.find((f) => f.id === s.currentFlowId);
};
