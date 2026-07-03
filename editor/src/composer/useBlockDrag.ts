// Drag & drop propio con pointer events (#178).
//
// ¿Por qué no HTML5 drag & drop? Tauri 2 en macOS (WKWebView) intercepta los
// eventos nativos de drag para su propio file-drop handler, así que dragstart
// nunca dispara dentro del webview — los handles estaban pintados pero el
// gesto no existía. Pointer events no pasan por ese pipeline y funcionan
// igual en el navegador (vite dev) y dentro de Tauri. Sin dependencias.
//
// Modelo:
// - El canvas delega: pointerdown sobre un `.drag-handle` inicia el gesto
//   para el bloque `[data-block-id]` más cercano (comando, componente o logic).
// - Contenedores droppables: la raíz del canvas (`[data-drop-root]`) y cada
//   slot de logic (`[data-drop-parent][data-drop-slot]` en LogicSlot).
// - En cada pointermove se hace hit-test con elementsFromPoint, se calcula el
//   índice de inserción por los midpoints verticales de los bloques hijos
//   directos del contenedor (excluyendo el bloque arrastrado) y se publica la
//   geometría del indicador para que BlockCanvas pinte la línea.
// - El índice se calcula SIN el bloque arrastrado — mismo contrato que
//   `moveBlockTo` (insertar después de remover), cero ajustes de índice.
// - ESC cancela; drop fuera de un contenedor válido cancela.

import { useCallback, useEffect, useRef, useState } from "react";
import type { DropTarget } from "../state/blockTree";

export interface DragIndicator {
  top: number;
  left: number;
  width: number;
}

interface Options {
  enabled: boolean;
  onDrop: (blockId: string, dest: DropTarget) => void;
}

const DRAG_THRESHOLD_PX = 5;
const SLOT_HOVER_CLASS = "slot-drop-hover";
const DRAGGING_CLASS = "block-dragging";

export function useBlockDrag(canvasRef: React.RefObject<HTMLElement | null>, opts: Options) {
  const [draggingId, setDraggingId] = useState<string | null>(null);
  const [indicator, setIndicator] = useState<DragIndicator | null>(null);

  // Refs para que los listeners de window vean estado fresco sin re-suscribir.
  const optsRef = useRef(opts);
  optsRef.current = opts;
  const session = useRef<{
    blockId: string;
    blockEl: HTMLElement;
    startX: number;
    startY: number;
    active: boolean;
    dest: DropTarget | null;
    hoverSlotEl: HTMLElement | null;
    cleanup: () => void;
  } | null>(null);

  const endDrag = useCallback((commit: boolean) => {
    const s = session.current;
    if (!s) return;
    session.current = null;
    s.cleanup();
    s.blockEl.classList.remove(DRAGGING_CLASS);
    s.hoverSlotEl?.classList.remove(SLOT_HOVER_CLASS);
    document.body.classList.remove("dnd-active");
    setDraggingId(null);
    setIndicator(null);
    if (commit && s.active && s.dest) {
      optsRef.current.onDrop(s.blockId, s.dest);
    }
  }, []);

  // Cleanup si el componente se desmonta a mitad de un drag.
  useEffect(() => () => endDrag(false), [endDrag]);

  const onPointerDown = useCallback(
    (e: React.PointerEvent) => {
      if (!optsRef.current.enabled || e.button !== 0 || session.current) return;
      const target = e.target as HTMLElement;
      const handle = target.closest<HTMLElement>(".drag-handle");
      if (!handle) return;
      const blockEl = handle.closest<HTMLElement>("[data-block-id]");
      const blockId = blockEl?.dataset.blockId;
      if (!blockEl || !blockId) return;

      e.preventDefault(); // evita selección de texto al arrastrar

      const canvas = canvasRef.current;

      function onMove(ev: PointerEvent) {
        const s = session.current;
        if (!s) return;
        if (!s.active) {
          const dist = Math.hypot(ev.clientX - s.startX, ev.clientY - s.startY);
          if (dist < DRAG_THRESHOLD_PX) return;
          s.active = true;
          s.blockEl.classList.add(DRAGGING_CLASS);
          document.body.classList.add("dnd-active");
          setDraggingId(s.blockId);
        }
        const hit = hitTest(ev.clientX, ev.clientY, s.blockEl, canvas);
        s.dest = hit?.dest ?? null;

        // Resaltar slot bajo el cursor.
        const slotEl = hit?.container.hasAttribute("data-drop-parent")
          ? hit.container
          : null;
        if (slotEl !== s.hoverSlotEl) {
          s.hoverSlotEl?.classList.remove(SLOT_HOVER_CLASS);
          slotEl?.classList.add(SLOT_HOVER_CLASS);
          s.hoverSlotEl = slotEl;
        }
        setIndicator(hit?.indicator ?? null);
      }
      function onUp() {
        endDrag(true);
      }
      function onKey(ev: KeyboardEvent) {
        if (ev.key === "Escape") {
          ev.stopPropagation();
          endDrag(false);
        }
      }
      const cleanup = () => {
        window.removeEventListener("pointermove", onMove);
        window.removeEventListener("pointerup", onUp);
        window.removeEventListener("pointercancel", onCancel);
        window.removeEventListener("keydown", onKey, true);
      };
      function onCancel() {
        endDrag(false);
      }

      session.current = {
        blockId,
        blockEl,
        startX: e.clientX,
        startY: e.clientY,
        active: false,
        dest: null,
        hoverSlotEl: null,
        cleanup,
      };

      window.addEventListener("pointermove", onMove);
      window.addEventListener("pointerup", onUp);
      window.addEventListener("pointercancel", onCancel);
      window.addEventListener("keydown", onKey, true);
    },
    [canvasRef, endDrag]
  );

  return { draggingId, indicator, onPointerDown };
}

// ──────────────────────────────────────────────────────────────────────────────
// Hit-testing puro sobre el DOM.

interface HitResult {
  container: HTMLElement;
  dest: DropTarget;
  indicator: DragIndicator;
}

function hitTest(
  x: number,
  y: number,
  draggedEl: HTMLElement,
  canvas: HTMLElement | null,
): HitResult | null {
  const container = findContainerAt(x, y, draggedEl, canvas);
  if (!container) return null;

  const items = directBlockChildren(container, draggedEl);
  let index = 0;
  for (const el of items) {
    const r = el.getBoundingClientRect();
    if (y > r.top + r.height / 2) index++;
  }

  const dest: DropTarget = container.hasAttribute("data-drop-parent")
    ? {
        parentId: container.dataset.dropParent!,
        slot: Number(container.dataset.dropSlot ?? 0),
        index,
      }
    : { index };

  return { container, dest, indicator: indicatorFor(container, items, index) };
}

/** Contenedor droppable más profundo bajo el cursor (excluye el subtree arrastrado). */
function findContainerAt(
  x: number,
  y: number,
  draggedEl: HTMLElement,
  canvas: HTMLElement | null,
): HTMLElement | null {
  for (const el of document.elementsFromPoint(x, y)) {
    if (!(el instanceof HTMLElement)) continue;
    // No se puede soltar dentro del propio bloque arrastrado.
    if (draggedEl.contains(el)) continue;
    if (el.hasAttribute("data-drop-parent") || el.hasAttribute("data-drop-root")) {
      if (draggedEl.contains(el)) continue;
      return el;
    }
  }
  // Fallback: si el puntero sigue dentro del canvas verticalmente pero salió
  // por un costado, tratamos la raíz como contenedor (drop "al nivel top").
  if (canvas) {
    const r = canvas.getBoundingClientRect();
    if (y >= r.top && y <= r.bottom) return canvas;
  }
  return null;
}

/** Bloques hijos directos del contenedor (sin descender a slots anidados). */
function directBlockChildren(container: HTMLElement, draggedEl: HTMLElement): HTMLElement[] {
  const all = container.querySelectorAll<HTMLElement>("[data-block-id]");
  const out: HTMLElement[] = [];
  for (const el of all) {
    if (el === draggedEl || draggedEl.contains(el)) continue;
    // El contenedor droppable más cercano por encima de este bloque debe ser
    // exactamente `container` — si no, pertenece a un slot anidado.
    const owner = el.parentElement?.closest("[data-drop-parent], [data-drop-root]");
    if (owner === container) out.push(el);
  }
  return out;
}

function indicatorFor(
  container: HTMLElement,
  items: HTMLElement[],
  index: number,
): DragIndicator {
  const cr = container.getBoundingClientRect();
  const left = cr.left + 8;
  const width = Math.max(40, cr.width - 16);
  if (items.length === 0) {
    return { top: cr.top + 6, left, width };
  }
  if (index >= items.length) {
    const r = items[items.length - 1].getBoundingClientRect();
    return { top: r.bottom + 2, left, width };
  }
  const r = items[index].getBoundingClientRect();
  return { top: r.top - 4, left, width };
}
