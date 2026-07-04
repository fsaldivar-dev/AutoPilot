import { beforeEach, describe, expect, it, vi } from "vitest";
import { render, screen } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { useStore } from "../state/store";
import { CommandBar } from "./CommandBar";
import type { Frame } from "../domain/types";
import { invoke } from "@tauri-apps/api/core";
import { resetElementsThrottleForTests } from "../services/elements";

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
    resetElementsThrottleForTests();
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

  // #180 — validación contra el catálogo + Enter con predictivo abierto.
  describe("validación del input (#180)", () => {
    it("comando desconocido NO se inserta como bloque: feedback inline", async () => {
      const user = userEvent.setup();
      render(<CommandBar platform="ios" />);
      const input = screen.getByTestId("command-bar-input");
      // "zzz" no matchea ninguna sugerencia → popover cerrado → Enter valida.
      await user.type(input, "zzz");
      await user.keyboard("{Enter}");

      expect(useStore.getState().projects[0].flows[0].blocks).toHaveLength(0);
      expect(mockedInvoke).not.toHaveBeenCalled();
      const err = screen.getByTestId("command-bar-error");
      expect(err.textContent).toContain("comando desconocido");
      expect(screen.getByTestId("command-bar").className).toContain("has-error");
      // El texto queda intacto para corregir.
      expect((input as HTMLInputElement).value).toBe("zzz");
    });

    it("texto parcial dismisseado tampoco se inserta (el caso de la `a` suelta)", async () => {
      const user = userEvent.setup();
      render(<CommandBar platform="ios" />);
      const input = screen.getByTestId("command-bar-input");
      await user.type(input, "a");
      // Escape cierra el predictivo; Enter ya no debe inyectar `a` como bloque.
      await user.keyboard("{Escape}");
      await user.keyboard("{Enter}");

      expect(useStore.getState().projects[0].flows[0].blocks).toHaveLength(0);
      expect(screen.getByTestId("command-bar-error")).toBeInTheDocument();
    });

    it("el error se limpia al volver a tipear", async () => {
      const user = userEvent.setup();
      render(<CommandBar platform="ios" />);
      const input = screen.getByTestId("command-bar-input");
      await user.type(input, "zzz");
      await user.keyboard("{Enter}");
      expect(screen.getByTestId("command-bar-error")).toBeInTheDocument();

      await user.type(input, "x");
      expect(screen.queryByTestId("command-bar-error")).toBeNull();
    });

    it("comando válido con args sí ejecuta (no lo bloquea la validación)", async () => {
      mockedInvoke.mockImplementation(async (cmd: string) => {
        if (cmd === "executor_spawn") return "sess_test";
        if (cmd === "executor_send") return { ok: true, ms: 10 } satisfies Frame;
        return null;
      });
      const user = userEvent.setup();
      render(<CommandBar platform="ios" />);
      const input = screen.getByTestId("command-bar-input");
      await user.type(input, 'tap "7"');
      await user.keyboard("{Enter}");

      await vi.waitFor(() => {
        const blocks = useStore.getState().projects[0].flows[0].blocks;
        expect(blocks).toHaveLength(1);
        expect(blocks[0].command).toBe('tap "7"');
        expect(blocks[0].meta.status).toBe("ok");
      });
      expect(screen.queryByTestId("command-bar-error")).toBeNull();
    });

    it("comando multi-palabra del catálogo pasa la validación", async () => {
      mockedInvoke.mockImplementation(async (cmd: string) => {
        if (cmd === "executor_spawn") return "sess_test";
        if (cmd === "executor_send") return { ok: true, ms: 10 } satisfies Frame;
        return null;
      });
      const user = userEvent.setup();
      render(<CommandBar platform="ios" />);
      const input = screen.getByTestId("command-bar-input");
      await user.type(input, "biometric enroll");
      // Escape para cerrar el popover: probamos la validación pura del run.
      await user.keyboard("{Escape}");
      await user.keyboard("{Enter}");

      await vi.waitFor(() => {
        const blocks = useStore.getState().projects[0].flows[0].blocks;
        expect(blocks).toHaveLength(1);
        expect(blocks[0].command).toBe("biometric enroll");
      });
    });
  });

  describe("Enter con predictivo abierto (#180)", () => {
    it("Enter acepta la sugerencia seleccionada — no inyecta el prefijo crudo", async () => {
      const user = userEvent.setup();
      render(<CommandBar platform="ios" />);
      const input = screen.getByTestId("command-bar-input");
      await user.type(input, "ta");
      await screen.findByTestId("autocomplete-popover");
      await user.keyboard("{Enter}");

      // Se completó a "tap " en vez de crear un bloque `ta`.
      expect((input as HTMLInputElement).value).toBe("tap ");
      expect(useStore.getState().projects[0].flows[0].blocks).toHaveLength(0);
      expect(mockedInvoke).not.toHaveBeenCalled();
    });

    it("Enter con la sugerencia ya aplicada ejecuta (segundo Enter = run)", async () => {
      mockedInvoke.mockImplementation(async (cmd: string) => {
        if (cmd === "executor_spawn") return "sess_test";
        if (cmd === "executor_send") return { ok: true, ms: 10, out: "PONG" } satisfies Frame;
        return null;
      });
      const user = userEvent.setup();
      render(<CommandBar platform="ios" />);
      const input = screen.getByTestId("command-bar-input");
      // "ping" es exactamente la sugerencia top → aceptar es no-op → ejecuta.
      await user.type(input, "ping");
      await user.keyboard("{Enter}");

      await vi.waitFor(() => {
        const blocks = useStore.getState().projects[0].flows[0].blocks;
        expect(blocks).toHaveLength(1);
        expect(blocks[0].command).toBe("ping");
        expect(blocks[0].meta.status).toBe("ok");
      });
    });

    it("Enter tras navegar con flechas acepta la sugerencia navegada", async () => {
      const user = userEvent.setup();
      render(<CommandBar platform="ios" />);
      const input = screen.getByTestId("command-bar-input");
      await user.type(input, "list");
      await screen.findByTestId("autocomplete-popover");
      await user.keyboard("{ArrowDown}");
      await user.keyboard("{Enter}");

      // Aceptó una sugerencia (la #1, no la #0) en vez de ejecutar "list".
      expect((input as HTMLInputElement).value).toMatch(/^list /);
      expect(useStore.getState().projects[0].flows[0].blocks).toHaveLength(0);
    });

    // #183 — comando multi-palabra: completar no debe duplicar el prefijo.
    it("Enter con comando multi-palabra completa sin duplicar; segundo Enter ejecuta", async () => {
      mockedInvoke.mockImplementation(async (cmd: string) => {
        if (cmd === "executor_spawn") return "sess_test";
        if (cmd === "executor_send") return { ok: true, ms: 10 } satisfies Frame;
        return null;
      });
      const user = userEvent.setup();
      render(<CommandBar platform="ios" />);
      const input = screen.getByTestId("command-bar-input");
      await user.type(input, "biometric enro");
      await screen.findByTestId("autocomplete-popover");
      await user.keyboard("{Enter}");

      // Antes: «biometric biometric enroll» y Enter en loop sin insertar nunca.
      expect((input as HTMLInputElement).value).toBe("biometric enroll");
      expect(useStore.getState().projects[0].flows[0].blocks).toHaveLength(0);

      await user.keyboard("{Enter}");
      await vi.waitFor(() => {
        const blocks = useStore.getState().projects[0].flows[0].blocks;
        expect(blocks).toHaveLength(1);
        expect(blocks[0].command).toBe("biometric enroll");
      });
    });

    // #189 — el flujo del screenshot: tap "desblo sin tree cargado. Con
    // sesión viva el índice viene de la SESIÓN (observer, sin robo de foco),
    // jamás del inspect frío (path AX → chrome del Simulator).
    it("auto-fetchea los elementos via la sesión al pedir un target sin tree", async () => {
      useStore.setState({ sessionId: "sess_live" });
      mockedInvoke.mockImplementation(async (cmd: string, args?: unknown) => {
        if (cmd === "executor_send" && (args as { line?: string })?.line === "tree") {
          return {
            ok: true,
            ms: 120,
            out: 'AXWindow  [0,0 402x874]\n  AXButton  label="Desbloquear con biometría"  [10,20 100x40]\n  AXStaticText  "Mis Viajes"  [20,60 200x30]',
          } satisfies Frame;
        }
        return null;
      });
      const user = userEvent.setup();
      render(<CommandBar platform="ios" />);
      const input = screen.getByTestId("command-bar-input");
      await user.type(input, 'tap "desblo');

      await vi.waitFor(() => {
        expect(useStore.getState().elements).toHaveLength(2);
      });
      expect(mockedInvoke).not.toHaveBeenCalledWith("inspect", expect.anything());
      // El popover se llena solo con el elemento real (match case-insensitive).
      const popover = await screen.findByTestId("autocomplete-popover");
      expect(popover.textContent).toContain("Desbloquear con biometría");
    });

    it("Escape cierra el popover sin borrar el texto", async () => {
      const user = userEvent.setup();
      render(<CommandBar platform="ios" />);
      const input = screen.getByTestId("command-bar-input");
      await user.type(input, "ta");
      await screen.findByTestId("autocomplete-popover");
      await user.keyboard("{Escape}");

      expect(screen.queryByTestId("autocomplete-popover")).toBeNull();
      expect((input as HTMLInputElement).value).toBe("ta");
    });
  });
});
