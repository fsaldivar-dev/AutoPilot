import { beforeEach, describe, expect, it } from "vitest";
import { useStore, selectCurrentFlow, selectCurrentProject } from "./store";
import type { Block, Flow, Project } from "../domain/types";

const mkProject = (id: string): Project => ({
  id,
  name: `Project ${id}`,
  platform: "ios",
  flows: [],
  components: [],
  env: [],
  devices: [],
  createdAt: Date.now(),
  updatedAt: Date.now(),
});

const mkFlow = (id: string, projectId: string): Flow => ({
  id,
  projectId,
  name: `Flow ${id}`,
  blocks: [],
  updatedAt: Date.now(),
});

const mkBlock = (id: string, command: string): Block => ({
  id,
  kind: "command",
  command,
  args: {},
  meta: { status: "idle" },
});

describe("useStore project slice", () => {
  beforeEach(() => {
    useStore.setState({
      projects: [],
      currentProjectId: undefined,
      currentFlowId: undefined,
      selectedBlockIds: [],
      sessionId: undefined,
      running: false,
      elements: [],
      recentBlocks: [],
      autocompleteOpen: false,
      autocompleteSuggestions: [],
      autocompleteInput: "",
      autocompleteCursor: 0,
    });
  });

  it("adds and lists projects", () => {
    const p = mkProject("p1");
    useStore.getState().addProject(p);
    expect(useStore.getState().projects).toHaveLength(1);
    expect(useStore.getState().projects[0].name).toBe("Project p1");
  });

  it("selectCurrentProject returns the current one", () => {
    const p = mkProject("p1");
    useStore.getState().addProject(p);
    useStore.getState().setCurrentProject("p1");
    const cur = selectCurrentProject(useStore.getState());
    expect(cur?.id).toBe("p1");
  });

  it("adds flow to project", () => {
    useStore.getState().addProject(mkProject("p1"));
    useStore.getState().addFlow("p1", mkFlow("f1", "p1"));
    useStore.getState().setCurrentProject("p1");
    useStore.getState().setCurrentFlow("f1");
    const flow = selectCurrentFlow(useStore.getState());
    expect(flow?.id).toBe("f1");
  });

  it("appends block to flow", () => {
    useStore.getState().addProject(mkProject("p1"));
    useStore.getState().addFlow("p1", mkFlow("f1", "p1"));
    useStore.getState().appendBlock("f1", mkBlock("b1", "ping"));
    useStore.getState().setCurrentProject("p1");
    useStore.getState().setCurrentFlow("f1");
    const flow = selectCurrentFlow(useStore.getState());
    expect(flow?.blocks).toHaveLength(1);
    expect(flow?.blocks[0].command).toBe("ping");
  });

  it("updates block meta on run", () => {
    useStore.getState().addProject(mkProject("p1"));
    useStore.getState().addFlow("p1", mkFlow("f1", "p1"));
    useStore.getState().appendBlock("f1", mkBlock("b1", "ping"));
    useStore
      .getState()
      .updateBlock("f1", "b1", { meta: { status: "ok", ms: 340 } });
    useStore.getState().setCurrentProject("p1");
    useStore.getState().setCurrentFlow("f1");
    const flow = selectCurrentFlow(useStore.getState());
    expect(flow?.blocks[0].meta.status).toBe("ok");
    expect(flow?.blocks[0].meta.ms).toBe(340);
  });

  it("moves block to new index", () => {
    useStore.getState().addProject(mkProject("p1"));
    useStore.getState().addFlow("p1", mkFlow("f1", "p1"));
    useStore.getState().appendBlock("f1", mkBlock("b1", "a"));
    useStore.getState().appendBlock("f1", mkBlock("b2", "b"));
    useStore.getState().appendBlock("f1", mkBlock("b3", "c"));
    useStore.getState().moveBlock("f1", "b3", 0);
    useStore.getState().setCurrentProject("p1");
    useStore.getState().setCurrentFlow("f1");
    const flow = selectCurrentFlow(useStore.getState());
    expect(flow?.blocks.map((b) => b.id)).toEqual(["b3", "b1", "b2"]);
  });

  it("upserts env var uniquely by scope+key", () => {
    useStore.getState().addProject(mkProject("p1"));
    useStore.getState().upsertEnvVar("p1", {
      projectId: "p1",
      scope: "staging",
      key: "API",
      value: "v1",
      secret: false,
    });
    useStore.getState().upsertEnvVar("p1", {
      projectId: "p1",
      scope: "staging",
      key: "API",
      value: "v2",
      secret: true,
    });
    const proj = useStore.getState().projects[0];
    expect(proj.env).toHaveLength(1);
    expect(proj.env[0].value).toBe("v2");
    expect(proj.env[0].secret).toBe(true);
  });
});

describe("useStore composer / executor slices", () => {
  beforeEach(() => {
    useStore.setState({ recentBlocks: [], elements: [] });
  });

  it("pushRecent caps at 20", () => {
    for (let i = 0; i < 25; i++) {
      useStore.getState().pushRecent(mkBlock(`b${i}`, `cmd${i}`));
    }
    expect(useStore.getState().recentBlocks).toHaveLength(20);
    expect(useStore.getState().recentBlocks[0].id).toBe("b24");
  });

  it("setSession updates executor state", () => {
    useStore.getState().setSession("s1", "ios");
    expect(useStore.getState().sessionId).toBe("s1");
    expect(useStore.getState().sessionPlatform).toBe("ios");
  });
});
