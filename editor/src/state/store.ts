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
  Project,
  Suggestion,
} from "../domain/types";

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
}

interface ExecutorSlice {
  sessionId?: string;
  sessionPlatform?: Platform;
  running: boolean;
  elements: IndexedElement[];
  recentBlocks: Block[];
  setSession: (id: string | undefined, platform?: Platform) => void;
  setRunning: (r: boolean) => void;
  setElements: (els: IndexedElement[]) => void;
  pushRecent: (block: Block) => void;
}

interface UiSlice {
  autocompleteOpen: boolean;
  autocompleteSuggestions: Suggestion[];
  autocompleteInput: string;
  autocompleteCursor: number;
  toast?: { level: "info" | "ok" | "err"; text: string };
  setAutocompleteOpen: (open: boolean) => void;
  setAutocompleteInput: (input: string, cursor: number) => void;
  setAutocompleteSuggestions: (s: Suggestion[]) => void;
  showToast: (level: "info" | "ok" | "err", text: string) => void;
  dismissToast: () => void;
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

  // executor
  sessionId: undefined,
  sessionPlatform: undefined,
  running: false,
  elements: [],
  recentBlocks: [],
  setSession: (id, platform) => set({ sessionId: id, sessionPlatform: platform }),
  setRunning: (r) => set({ running: r }),
  setElements: (elements) => set({ elements }),
  pushRecent: (block) =>
    set((s) => ({ recentBlocks: [block, ...s.recentBlocks].slice(0, 20) })),

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
}));

// Selector helpers

export const selectCurrentProject = (s: Store): Project | undefined =>
  s.projects.find((p) => p.id === s.currentProjectId);

export const selectCurrentFlow = (s: Store): Flow | undefined => {
  const proj = selectCurrentProject(s);
  return proj?.flows.find((f) => f.id === s.currentFlowId);
};
