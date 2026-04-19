import { beforeEach, describe, expect, it } from "vitest";
import { render, screen, within } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { AppShell } from "./AppShell";
import { useStore } from "../state/store";

function resetStore() {
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
    autocompleteInput: "",
    autocompleteCursor: 0,
    autocompleteSuggestions: [],
    toast: undefined,
  });
}

describe("AppShell", () => {
  beforeEach(resetStore);

  it("renders toolbar, empty state, and panels", () => {
    render(<AppShell />);
    expect(screen.getByTestId("toolbar")).toBeInTheDocument();
    expect(screen.getByText(/Sin proyectos/)).toBeInTheDocument();
    expect(screen.getByTestId("device-preview")).toBeInTheDocument();
  });

  it("platform toggle switches label", async () => {
    const user = userEvent.setup();
    render(<AppShell />);
    const toggle = screen.getByTestId("platform-toggle");
    await user.click(within(toggle).getByText("Android"));
    expect(screen.getByTestId("status-text").textContent).toMatch(/Android/);
  });

  it("creates new project via modal and selects it", async () => {
    const user = userEvent.setup();
    render(<AppShell />);

    await user.click(screen.getByTestId("new-project-btn"));
    const input = await screen.findByTestId("new-project-name");
    await user.type(input, "Banco Atlas");
    await user.click(screen.getByTestId("new-project-create"));

    expect(useStore.getState().projects).toHaveLength(1);
    expect(useStore.getState().projects[0].name).toBe("Banco Atlas");
    expect(useStore.getState().currentProjectId).toBeDefined();

    // The project created has one initial "Happy path" flow.
    const flows = useStore.getState().projects[0].flows;
    expect(flows).toHaveLength(1);
    expect(flows[0].name).toBe("Happy path");

    // Active flow displayed in toolbar.
    expect(screen.getByTestId("current-flow-label").textContent).toBe("Happy path");
  });

  it("canvas shows empty-state when no flow selected", () => {
    render(<AppShell />);
    expect(screen.getByText(/Selecciona un proyecto y un flow/)).toBeInTheDocument();
  });
});
