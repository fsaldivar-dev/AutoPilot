import { beforeEach, describe, expect, it, vi } from "vitest";
import { render, screen } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { useStore } from "../state/store";
import { InlineCommandEditor } from "./InlineCommandEditor";

function seedProject() {
  useStore.setState({
    projects: [
      {
        id: "p1",
        name: "Demo",
        platform: "ios",
        flows: [
          { id: "f1", projectId: "p1", name: "Flow 1", blocks: [], updatedAt: Date.now() },
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

// Validación de la edición inline de bloques (#182) — misma clase de bug
// que #180 en CommandBar: Enter guardaba texto crudo sin validar y sin
// aceptar la sugerencia del popover.
describe("InlineCommandEditor validación del input (#182)", () => {
  beforeEach(() => {
    seedProject();
  });

  it("comando desconocido NO se guarda: feedback inline y texto intacto", async () => {
    const user = userEvent.setup();
    const onSave = vi.fn();
    const onCancel = vi.fn();
    render(
      <InlineCommandEditor initial="" platform="ios" onSave={onSave} onCancel={onCancel} />
    );
    const input = screen.getByRole("textbox");
    await user.type(input, "zzz");
    await user.keyboard("{Enter}");

    expect(onSave).not.toHaveBeenCalled();
    const err = screen.getByTestId("inline-editor-error");
    expect(err.textContent).toContain("comando desconocido");
    expect(screen.getByTestId("inline-editor").className).toContain("has-error");
    expect((input as HTMLInputElement).value).toBe("zzz");
  });

  it("texto parcial dismisseado tampoco se guarda (el caso de la `a` suelta)", async () => {
    const user = userEvent.setup();
    const onSave = vi.fn();
    render(
      <InlineCommandEditor initial="" platform="ios" onSave={onSave} onCancel={vi.fn()} />
    );
    const input = screen.getByRole("textbox");
    await user.type(input, "a");
    await user.keyboard("{Escape}"); // cierra popover
    await user.keyboard("{Enter}");

    expect(onSave).not.toHaveBeenCalled();
    expect(screen.getByTestId("inline-editor-error")).toBeInTheDocument();
  });

  it("Enter con popover abierto ACEPTA la sugerencia, no guarda el prefijo crudo", async () => {
    const user = userEvent.setup();
    const onSave = vi.fn();
    render(
      <InlineCommandEditor initial="" platform="ios" onSave={onSave} onCancel={vi.fn()} />
    );
    const input = screen.getByRole("textbox");
    await user.type(input, "ta");
    await screen.findByTestId("autocomplete-popover");
    await user.keyboard("{Enter}");

    // Primer Enter completa (p.ej. "tap "), NO guarda el prefijo "ta".
    expect(onSave).not.toHaveBeenCalled();
    expect((input as HTMLInputElement).value).toMatch(/^tap\b/);
  });

  // #183 — comando multi-palabra: completar no debe duplicar el prefijo.
  it("multi-palabra: Enter completa sin duplicar y el segundo Enter guarda", async () => {
    const user = userEvent.setup();
    const onSave = vi.fn();
    render(
      <InlineCommandEditor initial="" platform="ios" onSave={onSave} onCancel={vi.fn()} />
    );
    const input = screen.getByRole("textbox");
    await user.type(input, "biometric enro");
    await screen.findByTestId("autocomplete-popover");
    await user.keyboard("{Enter}");

    // Antes: «biometric biometric enroll» y Enter en loop sin guardar nunca.
    expect((input as HTMLInputElement).value).toBe("biometric enroll");
    expect(onSave).not.toHaveBeenCalled();

    await user.keyboard("{Enter}");
    expect(onSave).toHaveBeenCalledWith("biometric enroll");
  });

  it("comando válido del catálogo se guarda", async () => {
    const user = userEvent.setup();
    const onSave = vi.fn();
    render(
      <InlineCommandEditor initial="" platform="ios" onSave={onSave} onCancel={vi.fn()} />
    );
    const input = screen.getByRole("textbox");
    await user.type(input, 'tap "Login"');
    await user.keyboard("{Escape}"); // dismiss del popover si quedó abierto
    await user.keyboard("{Enter}");

    expect(onSave).toHaveBeenCalledWith('tap "Login"');
  });

  it("keyword de lógica (if/repeat/try/assert) se guarda sin pasar por el catálogo", async () => {
    const user = userEvent.setup();
    const onSave = vi.fn();
    render(
      <InlineCommandEditor initial="" platform="ios" onSave={onSave} onCancel={vi.fn()} />
    );
    const input = screen.getByRole("textbox");
    await user.type(input, "repeat 3 times");
    await user.keyboard("{Escape}");
    await user.keyboard("{Enter}");

    expect(onSave).toHaveBeenCalledWith("repeat 3 times");
  });

  it("el error se limpia al volver a tipear", async () => {
    const user = userEvent.setup();
    render(
      <InlineCommandEditor initial="" platform="ios" onSave={vi.fn()} onCancel={vi.fn()} />
    );
    const input = screen.getByRole("textbox");
    await user.type(input, "zzz");
    await user.keyboard("{Enter}");
    expect(screen.getByTestId("inline-editor-error")).toBeInTheDocument();

    await user.type(input, "x");
    expect(screen.queryByTestId("inline-editor-error")).toBeNull();
  });

  it("editar un bloque existente a un comando inválido no lo persiste", async () => {
    const user = userEvent.setup();
    const onSave = vi.fn();
    render(
      <InlineCommandEditor
        initial='tap "Login"'
        platform="ios"
        onSave={onSave}
        onCancel={vi.fn()}
      />
    );
    const input = screen.getByRole("textbox") as HTMLInputElement;
    await user.clear(input);
    await user.type(input, "tapp algo");
    await user.keyboard("{Escape}");
    await user.keyboard("{Enter}");

    expect(onSave).not.toHaveBeenCalled();
    expect(screen.getByTestId("inline-editor-error").textContent).toContain("tapp");
  });
});
