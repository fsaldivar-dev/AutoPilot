import { useEffect, useState } from "react";
import { BlockCanvas } from "../composer/BlockCanvas";
import { ComponentLibrary } from "../library/ComponentLibrary";
import { DevicePreview } from "../inspector/DevicePreview";
import { FlowList } from "../projects/FlowList";
import { NewProjectModal } from "../projects/NewProjectModal";
import { ProjectList } from "../projects/ProjectList";
import { Timeline } from "../timeline/Timeline";
import { Toolbar } from "../toolbar/Toolbar";
import { EnvChips } from "../toolbar/EnvChips";
import { useStore } from "../state/store";
import type { Platform } from "../domain/types";
import * as dbService from "../services/db";

function loadProjectsIntoStore() {
  dbService
    .listProjects()
    .then(async (projects) => {
      if (!projects || projects.length === 0) return;
      const hydrated = await Promise.all(
        projects.map(async (p) => {
          const [flows, components, env] = await Promise.all([
            dbService.listFlows(p.id).catch(() => []),
            dbService.listComponents(p.id).catch(() => []),
            dbService.listEnvVars(p.id).catch(() => []),
          ]);
          return { ...p, flows, components, env };
        })
      );
      useStore.getState().setProjects(hydrated);
    })
    .catch(() => {
      // No Tauri runtime in tests; ignore.
    });
}

export function AppShell() {
  const [platform, setPlatform] = useState<Platform>("ios");
  const [showNewProject, setShowNewProject] = useState(false);
  const toast = useStore((s) => s.toast);
  const dismissToast = useStore((s) => s.dismissToast);

  useEffect(() => {
    loadProjectsIntoStore();
  }, []);

  useEffect(() => {
    if (toast) {
      const t = setTimeout(dismissToast, 3500);
      return () => clearTimeout(t);
    }
  }, [toast, dismissToast]);

  return (
    <div className="app-shell">
      <Toolbar platform={platform} setPlatform={setPlatform} />
      <aside className="panel-left">
        <ProjectList onNewProject={() => setShowNewProject(true)} />
        <FlowList />
        <ComponentLibrary />
        <EnvChips />
      </aside>
      <main className="panel-main">
        <BlockCanvas platform={platform} />
      </main>
      <aside className="panel-right">
        <DevicePreview platform={platform} />
        <Timeline />
      </aside>
      <footer className="status-bar">
        <span data-testid="status-text">
          {platform === "ios" ? "iPhone 15 Pro" : "Android emulator"} ·{" "}
          <span style={{ color: "var(--mint)" }}>conectado</span>
        </span>
        <span style={{ flex: 1 }} />
        <span style={{ color: "var(--text-mute)" }}>Composer v0.2</span>
      </footer>
      {showNewProject && <NewProjectModal onClose={() => setShowNewProject(false)} />}
      {toast && (
        <div className={`toast ${toast.level}`} data-testid="toast" onClick={dismissToast}>
          {toast.text}
        </div>
      )}
    </div>
  );
}
