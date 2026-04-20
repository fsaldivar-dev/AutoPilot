import { beforeEach, describe, expect, it, vi } from "vitest";
import { render, screen } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { useStore } from "../state/store";
import { CommandBar } from "./CommandBar";
import type { Frame } from "../domain/types";
import { invoke } from "@tauri-apps/api/core";

const mockedInvoke = vi.mocked(invoke);

function seedProjectAndFlow() {
  useStore.setState({
    projects: [
      {
        id: "p1",
        name: "Demo",
        platform: "ios",
        flows: [
          {
            id: "f1",
            projectId: "p1",
            name: "Flow 1",
            blocks: [],
            updatedAt: Date.now(),
          },
        ],
        components: [],
        env: [],
        devices: [],
        createdAt: Date.now(),
        updatedAt: Date.now(),
      },
    ],
    currentProjectId: "p1",
    currentFlowId: "f1",
    selectedBlockIds: [],
    sessionId: undefined,
    running: false,
    elements: [],
    recentBlocks: [],
  });
}

describe("CommandBar", () => {
  beforeEach(() => {
    seedProjectAndFlow();
    mockedInvoke.mockReset();
  });

  it("shows autocomplete suggestions when typing", async () => {
    const user = userEvent.setup();
    render(<CommandBar platform="ios" />);
    const input = screen.getByTestId("command-bar-input");
    await user.type(input, "ta");
    const popover = await screen.findByTestId("autocomplete-popover");
    expect(popover).toBeInTheDocument();
    const firstSuggestion = popover.querySelector('[data-testid="suggestion-0"]');
    expect(firstSuggestion?.textContent).toMatch(/tap/);
  });

  it("Tab picks the first suggestion", async () => {
    const user = userEvent.setup();
    render(<CommandBar platform="ios" />);
    const input = screen.getByTestId("command-bar-input");
    await user.type(input, "pin");
    await user.keyboard("{Tab}");
    expect((input as HTMLInputElement).value).toMatch(/ping/);
  });

  it("Enter spawns session and executes command as block", async () => {
    // Arrange: mock executor_spawn + executor_send
    mockedInvoke.mockImplementation(async (cmd: string, _args?: unknown) => {
      if (cmd === "executor_spawn") return "sess_test";
      if (cmd === "executor_send") {
        const frame: Frame = { ok: true, ms: 340, out: "PONG" };
        return frame;
      }
      return null;
    });

    const user = userEvent.setup();
    render(<CommandBar platform="ios" />);
    const input = screen.getByTestId("command-bar-input");
    await user.type(input, "ping");
    await user.keyboard("{Enter}");

    // Wait for the block to appear in the store with ok status.
    await vi.waitFor(() => {
      const blocks = useStore.getState().projects[0].flows[0].blocks;
      expect(blocks).toHaveLength(1);
      expect(blocks[0].command).toBe("ping");
      expect(blocks[0].meta.status).toBe("ok");
      expect(blocks[0].meta.ms).toBe(340);
    });
  });

  it("marks block as err when executor returns ok=false", async () => {
    mockedInvoke.mockImplementation(async (cmd: string) => {
      if (cmd === "executor_spawn") return "sess_test";
      if (cmd === "executor_send")
        return { ok: false, ms: 5000, err: "Element not found" } satisfies Frame;
      return null;
    });

    const user = userEvent.setup();
    render(<CommandBar platform="ios" />);
    const input = screen.getByTestId("command-bar-input");
    await user.type(input, 'tap "Login"');
    await user.keyboard("{Enter}");

    await vi.waitFor(() => {
      const blocks = useStore.getState().projects[0].flows[0].blocks;
      expect(blocks).toHaveLength(1);
      expect(blocks[0].meta.status).toBe("err");
      expect(blocks[0].meta.error).toContain("Element not found");
    });
  });
});
