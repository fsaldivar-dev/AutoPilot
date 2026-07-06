import { beforeEach, describe, expect, it, vi } from "vitest";
import { invoke } from "@tauri-apps/api/core";
import { ensureSessionForPlatform, projectConfig } from "./executor";
import { useStore } from "../state/store";
import type { Project } from "../domain/types";

const mockedInvoke = vi.mocked(invoke);

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

// #198 — la sesión debe ser de la plataforma que se va a correr.
describe("ensureSessionForPlatform", () => {
  beforeEach(() => {
    mockedInvoke.mockReset();
    useStore.setState({ sessionId: undefined, sessionPlatform: undefined, projects: [], currentProjectId: undefined });
  });

  it("reusa la sesión si la plataforma coincide", async () => {
    useStore.setState({ sessionId: "sess_ios", sessionPlatform: "ios" });
    const id = await ensureSessionForPlatform("ios");
    expect(id).toBe("sess_ios");
    expect(mockedInvoke).not.toHaveBeenCalledWith("executor_spawn", expect.anything());
  });

  it("mata y respawnea cuando la plataforma cambia (iOS→Android)", async () => {
    useStore.setState({ sessionId: "sess_ios", sessionPlatform: "ios" });
    mockedInvoke.mockImplementation(async (cmd: string) => {
      if (cmd === "executor_spawn") return "sess_android";
      return null;
    });
    const id = await ensureSessionForPlatform("android");
    expect(mockedInvoke).toHaveBeenCalledWith("executor_kill", { sessionId: "sess_ios" });
    expect(id).toBe("sess_android");
    expect(useStore.getState().sessionPlatform).toBe("android");
  });

  it("spawnea sin matar cuando no hay sesión previa", async () => {
    mockedInvoke.mockImplementation(async (cmd: string) => {
      if (cmd === "executor_spawn") return "sess_new";
      return null;
    });
    const id = await ensureSessionForPlatform("ios");
    expect(mockedInvoke).not.toHaveBeenCalledWith("executor_kill", expect.anything());
    expect(id).toBe("sess_new");
  });
});
