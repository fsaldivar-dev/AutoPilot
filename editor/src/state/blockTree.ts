// Helpers puros para manipular `Block[]` con estructura jerárquica (slots).
// Invariante clave: todos los helpers **preservan identity** (`===`) de
// cualquier bloque que no fue tocado por la operación. Crítico para Zustand
// selectors y React useMemo — evita rerenders masivos.

import type { Block } from "../domain/types";

export interface FindResult {
  block: Block;
  parentId?: string;
  slotIndex?: number;
}

/** Busca un bloque por id en todo el árbol (incluye slots). */
export function findBlock(blocks: Block[], id: string, parentId?: string): FindResult | null {
  for (const b of blocks) {
    if (b.id === id) return { block: b, parentId };
    if (b.slots) {
      for (let s = 0; s < b.slots.length; s++) {
        const r = findBlock(b.slots[s], id, b.id);
        if (r) {
          // Cuando encontramos directamente en el slot de este parent,
          // enriquecemos slotIndex.
          if (r.parentId === b.id && r.slotIndex === undefined) {
            return { ...r, slotIndex: s };
          }
          return r;
        }
      }
    }
  }
  return null;
}

/** Inserta `child` al final del `slot` del bloque con `parentId`. */
export function insertIntoSlot(
  blocks: Block[],
  parentId: string,
  slot: number,
  child: Block,
): Block[] {
  return blocks.map(b => {
    if (b.id === parentId) {
      const newSlots = ensureSlots(b.slots, slot + 1);
      const updated = newSlots.map((s, idx) =>
        idx === slot ? [...s, child] : s,
      );
      return { ...b, slots: updated };
    }
    if (b.slots) {
      const newSlots = b.slots.map(s => insertIntoSlot(s, parentId, slot, child));
      if (slotsChanged(b.slots, newSlots)) {
        return { ...b, slots: newSlots };
      }
    }
    return b;
  });
}

/** Elimina un bloque de un slot específico del parent. No-op si no lo encuentra. */
export function removeFromSlot(
  blocks: Block[],
  parentId: string,
  slot: number,
  blockId: string,
): Block[] {
  return blocks.map(b => {
    if (b.id === parentId && b.slots && b.slots[slot]) {
      const newSlot = b.slots[slot].filter(c => c.id !== blockId);
      if (newSlot.length === b.slots[slot].length) return b;     // no change
      const newSlots = b.slots.map((s, i) => (i === slot ? newSlot : s));
      return { ...b, slots: newSlots };
    }
    if (b.slots) {
      const newSlots = b.slots.map(s => removeFromSlot(s, parentId, slot, blockId));
      if (slotsChanged(b.slots, newSlots)) {
        return { ...b, slots: newSlots };
      }
    }
    return b;
  });
}

/** Reordena un bloque dentro del mismo slot a una nueva posición. */
export function moveWithinSlot(
  blocks: Block[],
  parentId: string,
  slot: number,
  blockId: string,
  toIndex: number,
): Block[] {
  return blocks.map(b => {
    if (b.id === parentId && b.slots && b.slots[slot]) {
      const src = b.slots[slot];
      const from = src.findIndex(c => c.id === blockId);
      if (from < 0 || from === toIndex) return b;
      const arr = [...src];
      const [item] = arr.splice(from, 1);
      arr.splice(toIndex, 0, item);
      const newSlots = b.slots.map((s, i) => (i === slot ? arr : s));
      return { ...b, slots: newSlots };
    }
    if (b.slots) {
      const newSlots = b.slots.map(s =>
        moveWithinSlot(s, parentId, slot, blockId, toIndex),
      );
      if (slotsChanged(b.slots, newSlots)) {
        return { ...b, slots: newSlots };
      }
    }
    return b;
  });
}

/** Actualiza un bloque (en cualquier profundidad) vía transformación pura. */
export function updateBlockById(
  blocks: Block[],
  id: string,
  transform: (b: Block) => Block,
): Block[] {
  return blocks.map(b => {
    if (b.id === id) return transform(b);
    if (b.slots) {
      const newSlots = b.slots.map(s => updateBlockById(s, id, transform));
      if (slotsChanged(b.slots, newSlots)) {
        return { ...b, slots: newSlots };
      }
    }
    return b;
  });
}

// ──────────────────────────────────────────────────────────────────────────────
// Drag & drop — mover un bloque a cualquier contenedor (raíz o slot).

/**
 * Destino de un drop.
 * - `parentId === undefined` → raíz del flow.
 * - `index` se interpreta DESPUÉS de remover el bloque arrastrado de su
 *   contenedor origen (así el hit-test del DOM, que excluye al bloque
 *   arrastrado, produce índices consistentes sin ajustes).
 */
export interface DropTarget {
  parentId?: string;
  slot?: number;
  index: number;
}

/** Ubicación actual de un bloque: contenedor + índice dentro de él. */
export function locateBlock(
  blocks: Block[],
  id: string,
): { parentId?: string; slot?: number; index: number } | null {
  const idx = blocks.findIndex(b => b.id === id);
  if (idx >= 0) return { index: idx };
  for (const b of blocks) {
    if (!b.slots) continue;
    for (let s = 0; s < b.slots.length; s++) {
      const direct = b.slots[s].findIndex(c => c.id === id);
      if (direct >= 0) return { parentId: b.id, slot: s, index: direct };
      const deep = locateBlock(b.slots[s], id);
      if (deep) return deep;
    }
  }
  return null;
}

/**
 * Mueve un bloque (de cualquier profundidad) al destino dado.
 * Soporta: reorden en raíz, raíz → slot, slot → raíz, slot → slot.
 * No-op (devuelve el array original) si:
 * - el bloque no existe,
 * - el destino es el propio bloque o un descendiente suyo (ciclo),
 * - el movimiento no cambia la posición.
 */
export function moveBlockTo(blocks: Block[], blockId: string, dest: DropTarget): Block[] {
  const found = findBlock(blocks, blockId);
  if (!found) return blocks;

  // Guard anti-ciclo: no soltar dentro de sí mismo ni de un descendiente.
  if (dest.parentId !== undefined) {
    if (dest.parentId === blockId) return blocks;
    if (findBlock(found.block.slots?.flat() ?? [], dest.parentId)) return blocks;
    // El parent destino debe existir.
    const parent = findBlock(blocks, dest.parentId);
    if (!parent || parent.block.kind !== "logic") return blocks;
  }

  const src = locateBlock(blocks, blockId);
  if (!src) return blocks;

  // No-op: mismo contenedor y misma posición resultante.
  if (
    src.parentId === dest.parentId &&
    (src.parentId === undefined || src.slot === dest.slot) &&
    src.index === dest.index
  ) {
    return blocks;
  }

  // 1) Remover del origen.
  const without =
    src.parentId === undefined
      ? blocks.filter(b => b.id !== blockId)
      : removeFromSlot(blocks, src.parentId, src.slot!, blockId);

  // 2) Insertar en destino (índice clampeado al tamaño del contenedor).
  if (dest.parentId === undefined) {
    const arr = [...without];
    arr.splice(clamp(dest.index, arr.length), 0, found.block);
    return arr;
  }
  return insertIntoSlotAt(without, dest.parentId, dest.slot ?? 0, dest.index, found.block);
}

/** Inserta `child` en la posición `index` del slot (clampeado). */
function insertIntoSlotAt(
  blocks: Block[],
  parentId: string,
  slot: number,
  index: number,
  child: Block,
): Block[] {
  return blocks.map(b => {
    if (b.id === parentId) {
      const newSlots = ensureSlots(b.slots, slot + 1);
      const updated = newSlots.map((s, idx) => {
        if (idx !== slot) return s;
        const arr = [...s];
        arr.splice(clamp(index, arr.length), 0, child);
        return arr;
      });
      return { ...b, slots: updated };
    }
    if (b.slots) {
      const newSlots = b.slots.map(s => insertIntoSlotAt(s, parentId, slot, index, child));
      if (slotsChanged(b.slots, newSlots)) {
        return { ...b, slots: newSlots };
      }
    }
    return b;
  });
}

function clamp(i: number, max: number): number {
  return Math.max(0, Math.min(i, max));
}

// ──────────────────────────────────────────────────────────────────────────────
// Internals

function ensureSlots(slots: Block[][] | undefined, minLength: number): Block[][] {
  const base = slots ? [...slots] : [];
  while (base.length < minLength) base.push([]);
  return base;
}

function slotsChanged(a: Block[][], b: Block[][]): boolean {
  if (a.length !== b.length) return true;
  for (let i = 0; i < a.length; i++) {
    if (a[i] !== b[i]) {
      // Verificar si los elementos de slot cambiaron (referencial)
      if (a[i].length !== b[i].length) return true;
      for (let j = 0; j < a[i].length; j++) {
        if (a[i][j] !== b[i][j]) return true;
      }
    }
  }
  return false;
}
