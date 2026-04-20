import { useEffect, useState } from "react";
import { BlockCanvas } from "../composer/BlockCanvas";
import { CodeView } from "../composer/CodeView";
import { ComponentLibrary } from "../library/ComponentLibrary";
import { DevicePreview } from "../inspector/DevicePreview";
import { FlowList } from "../projects/FlowList";
import { NewProjectModal } from "../projects/NewProjectModal";
import { ProjectList } from "../projects/ProjectList";
import { PrimitivesPalette } from "../composer/PrimitivesPalette";
import { LogicPalette } from "../composer/LogicPalette";
import { BlockProperties } from "../inspector/BlockProperties";
import { Timeline } from "../timeline/Timeline";
import { Toolbar } from "../toolbar/Toolbar";
import { EnvChips } from "../toolbar/EnvChips";
import { useStore } from "../state/store";
import type { Platform } from "../domain/types";
import { hydrateFromDisk, startAutoSave } from "../services/persistence";

export function AppShell() {
  const [platform, setPlatform] = useState<Platform>("ios");
  const [showNewProject, setShowNewProject] = useState(false);
  const toast = useStore((s) => s.toast);
  const dismissToast = useStore((s) => s.dismissToast);
  const selectedIds = useStore((s) => s.selectedBlockIds);
  const viewMode = useStore((s) => s.viewMode);

  useEffect(() => {
    void hydrateFromDisk();
    const unsub = startAutoSave(500);
    return () => unsub();
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
        <PrimitivesPalette platform={platform} />
        <LogicPalette />
        <EnvChips />
      </aside>
      <main className="panel-main">
        {viewMode === "code" ? <CodeView /> : <BlockCanvas platform={platform} />}
      </main>
      <aside className="panel-right">
        <DevicePreview platform={platform} />
        {selectedIds.length === 1 ? <BlockProperties /> : <Timeline />}
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
