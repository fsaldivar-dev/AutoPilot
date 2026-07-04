import { describe, expect, it } from "vitest";
import { projectConfig } from "./executor";
import { useStore } from "../state/store";
import type { Project } from "../domain/types";

function proj(extra: Partial<Project>): Project {
  return {
    id: "p1",
    name: "Demo",
    platform: "ios",
    flows: [],
    components: [],
    env: [],
    devices: [],
    createdAt: 0,
    updatedAt: 0,
    ...extra,
  };
}

// #193 — la config del proyecto viaja al spawn como `.autopilot` de sesión.
describe("projectConfig", () => {
  it("bundle + image del proyecto activo", () => {
    useStore.setState({
      projects: [proj({ bundleId: "com.x.app", cameraImage: "/tmp/foto.jpg" })],
      currentProjectId: "p1",
    });
    expect(projectConfig()).toEqual({ bundle: "com.x.app", image: "/tmp/foto.jpg" });
  });

  it("solo bundle si no hay imagen", () => {
    useStore.setState({ projects: [proj({ bundleId: "com.x.app" })], currentProjectId: "p1" });
    expect(projectConfig()).toEqual({ bundle: "com.x.app" });
  });

  it("null sin proyecto o sin campos (el CLI no recibe config vacía)", () => {
    useStore.setState({ projects: [proj({})], currentProjectId: "p1" });
    expect(projectConfig()).toBeNull();
    useStore.setState({ projects: [], currentProjectId: undefined });
    expect(projectConfig()).toBeNull();
  });
});
