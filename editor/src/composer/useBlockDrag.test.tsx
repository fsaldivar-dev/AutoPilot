// Test de comportamiento del gesto drag & drop (#178) — pointerdown en el
// handle → pointermove → pointerup dispara onDrop con el DropTarget correcto.
// jsdom no tiene layout, así que se stubbean getBoundingClientRect y
// document.elementsFromPoint con una geometría vertical simple:
//
//   canvas  (0..300)
//     [a]     0..20
//     [b]    20..40
//     [if1]  40..100   (su slot0: 60..90)
//
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { cleanup, fireEvent, render, screen } from "@testing-library/react";
import { useRef } from "react";
import { useBlockDrag } from "./useBlockDrag";
import type { DropTarget } from "../state/blockTree";

function Harness({ onDrop, enabled = true }: { onDrop: (id: string, d: DropTarget) => void; enabled?: boolean }) {
  const ref = useRef<HTMLDivElement>(null);
  const { draggingId, indicator, onPointerDown } = useBlockDrag(ref, { enabled, onDrop });
  return (
    <div ref={ref} data-drop-root data-testid="canvas" onPointerDown={onPointerDown}>
      <div data-block-id="a" data-testid="block-a">
        <span className="drag-handle" data-testid="handle-a">⋮⋮</span>
      </div>
      <div data-block-id="b" data-testid="block-b">
        <span className="drag-handle">⋮⋮</span>
      </div>
      <div data-block-id="if1" data-testid="block-if1">
        <span className="drag-handle" data-testid="handle-if1">⋮⋮</span>
        <div className="logic-slot" data-drop-parent="if1" data-drop-slot="0" data-testid="slot0" />
      </div>
      {draggingId && indicator && <div data-testid="indicator" />}
    </div>
  );
}

function rect(top: number, height: number): DOMRect {
  return {
    top, bottom: top + height, height,
    left: 0, right: 200, width: 200, x: 0, y: top,
    toJSON: () => ({}),
  } as DOMRect;
}

function stubGeometry() {
  const geo: Array<[string, number, number]> = [
    ["canvas", 0, 300],
    ["block-a", 0, 20],
    ["block-b", 20, 20],
    ["block-if1", 40, 60],
    ["slot0", 60, 30],
  ];
  for (const [testid, top, height] of geo) {
    const el = screen.getByTestId(testid);
    el.getBoundingClientRect = () => rect(top, height);
  }
  // Hit-test por coordenada Y: dentro del slot devuelve [slot, if1, canvas],
  // si no, [bloque?, canvas].
  document.elementsFromPoint = (_x: number, y: number) => {
    const canvas = screen.getByTestId("canvas");
    if (y >= 60 && y <= 90) {
      return [screen.getByTestId("slot0"), screen.getByTestId("block-if1"), canvas];
    }
    const hit = ["block-a", "block-b", "block-if1"].find((t) => {
      const r = screen.getByTestId(t).getBoundingClientRect();
      return y >= r.top && y <= r.bottom;
    });
    return hit ? [screen.getByTestId(hit), canvas] : [canvas];
  };
}

// jsdom no implementa PointerEvent — despachamos MouseEvent con el type
// pointer correspondiente (React y el hook solo leen clientX/clientY/button).
function ptr(type: string, x: number, y: number): MouseEvent {
  return new MouseEvent(type, {
    bubbles: true, cancelable: true, clientX: x, clientY: y, button: 0,
  });
}

function drag(handle: HTMLElement, path: Array<[number, number]>, end: "up" | "escape") {
  const [x0, y0] = path[0];
  fireEvent(handle, ptr("pointerdown", x0, y0));
  for (const [x, y] of path.slice(1)) {
    fireEvent(window, ptr("pointermove", x, y));
  }
  const [xe, ye] = path[path.length - 1];
  if (end === "escape") {
    fireEvent.keyDown(window, { key: "Escape" });
    // pointerup posterior no debe commitear nada
    fireEvent(window, ptr("pointerup", xe, ye));
  } else {
    fireEvent(window, ptr("pointerup", xe, ye));
  }
}

describe("useBlockDrag", () => {
  const onDrop = vi.fn();
  beforeEach(() => {
    onDrop.mockClear();
    render(<Harness onDrop={onDrop} />);
    stubGeometry();
  });
  afterEach(() => {
    cleanup();
    document.body.classList.remove("dnd-active");
  });

  it("reordena al mismo nivel: a → después de b", () => {
    // y=35 → mitad inferior de b → índice 1 (sin contar a, que va en la mano)
    drag(screen.getByTestId("handle-a"), [[5, 5], [5, 15], [5, 35]], "up");
    expect(onDrop).toHaveBeenCalledWith("a", { index: 1 });
  });

  it("mueve a un slot de logic block", () => {
    drag(screen.getByTestId("handle-a"), [[5, 5], [5, 15], [5, 75]], "up");
    expect(onDrop).toHaveBeenCalledWith("a", { parentId: "if1", slot: 0, index: 0 });
  });

  it("resalta el slot y muestra el indicador durante el hover", () => {
    const handle = screen.getByTestId("handle-a");
    fireEvent(handle, ptr("pointerdown", 5, 5));
    fireEvent(window, ptr("pointermove", 5, 15));
    fireEvent(window, ptr("pointermove", 5, 75));
    expect(screen.getByTestId("slot0").classList.contains("slot-drop-hover")).toBe(true);
    expect(screen.getByTestId("indicator")).toBeTruthy();
    expect(screen.getByTestId("block-a").classList.contains("block-dragging")).toBe(true);
    fireEvent(window, ptr("pointerup", 5, 75));
    expect(screen.getByTestId("slot0").classList.contains("slot-drop-hover")).toBe(false);
  });

  it("ESC cancela el drag sin soltar", () => {
    drag(screen.getByTestId("handle-a"), [[5, 5], [5, 15], [5, 35]], "escape");
    expect(onDrop).not.toHaveBeenCalled();
    expect(document.body.classList.contains("dnd-active")).toBe(false);
  });

  it("un click sin movimiento no dispara drag", () => {
    const handle = screen.getByTestId("handle-a");
    fireEvent(handle, ptr("pointerdown", 5, 5));
    fireEvent(window, ptr("pointerup", 5, 5));
    expect(onDrop).not.toHaveBeenCalled();
  });

  it("los logic blocks también se arrastran (handle en el header)", () => {
    // if1 → antes de a (y=5, mitad superior de a → índice 0)
    drag(screen.getByTestId("handle-if1"), [[5, 45], [5, 55], [5, 5]], "up");
    expect(onDrop).toHaveBeenCalledWith("if1", { index: 0 });
  });

  it("no inicia drag cuando está deshabilitado (running/editing)", () => {
    cleanup();
    render(<Harness onDrop={onDrop} enabled={false} />);
    stubGeometry();
    drag(screen.getByTestId("handle-a"), [[5, 5], [5, 15], [5, 35]], "up");
    expect(onDrop).not.toHaveBeenCalled();
  });
});
