import { describe, expect, it } from "vitest";
import type { Block } from "../domain/types";
import {
  findBlock,
  insertIntoSlot,
  locateBlock,
  moveBlockTo,
  removeFromSlot,
  moveWithinSlot,
  updateBlockById,
} from "./blockTree";

function cmd(id: string): Block {
  return { id, kind: "command", command: `tap ${id}`, meta: { status: "idle" } };
}
function iff(id: string, thenBlocks: Block[], elseBlocks: Block[] = []): Block {
  return {
    id, kind: "logic", logicKind: "if",
    predicate: { kind: "call", name: "exists", args: ["X"] },
    slots: [thenBlocks, elseBlocks],
    meta: { status: "idle" },
  };
}

describe("blockTree", () => {
  describe("findBlock", () => {
    it("finds at level 0", () => {
      const blocks = [cmd("a"), cmd("b")];
      const r = findBlock(blocks, "b");
      expect(r?.block.id).toBe("b");
      expect(r?.parentId).toBeUndefined();
    });

    it("finds nested inside if then", () => {
      const inner = cmd("inner");
      const blocks = [iff("ifA", [inner])];
      const r = findBlock(blocks, "inner");
      expect(r?.block.id).toBe("inner");
      expect(r?.parentId).toBe("ifA");
      expect(r?.slotIndex).toBe(0);
    });

    it("finds nested 2 levels deep", () => {
      const inner = cmd("inner");
      const blocks = [iff("outer", [iff("inner-if", [inner])])];
      const r = findBlock(blocks, "inner");
      expect(r?.block.id).toBe("inner");
      expect(r?.parentId).toBe("inner-if");
      expect(r?.slotIndex).toBe(0);
    });

    it("returns null when missing", () => {
      expect(findBlock([cmd("a")], "z")).toBeNull();
    });
  });

  describe("insertIntoSlot", () => {
    it("inserts into top-level logic then slot", () => {
      const blocks = [iff("ifA", [])];
      const out = insertIntoSlot(blocks, "ifA", 0, cmd("new"));
      const ifNew = out[0];
      expect(ifNew.slots?.[0].map(b => b.id)).toEqual(["new"]);
      expect(ifNew.slots?.[1]).toEqual([]);
    });

    it("inserts into else slot", () => {
      const blocks = [iff("ifA", [cmd("t")])];
      const out = insertIntoSlot(blocks, "ifA", 1, cmd("e"));
      expect(out[0].slots?.[1].map(b => b.id)).toEqual(["e"]);
    });

    it("preserves identity of unrelated blocks", () => {
      const c = cmd("sibling");
      const blocks = [c, iff("ifA", [])];
      const out = insertIntoSlot(blocks, "ifA", 0, cmd("new"));
      expect(out[0]).toBe(c);         // sibling untouched
    });
  });

  describe("removeFromSlot", () => {
    it("removes block from slot", () => {
      const blocks = [iff("ifA", [cmd("t1"), cmd("t2")])];
      const out = removeFromSlot(blocks, "ifA", 0, "t1");
      expect(out[0].slots?.[0].map(b => b.id)).toEqual(["t2"]);
    });

    it("returns same structure if block not found (no-op)", () => {
      const blocks = [iff("ifA", [cmd("t1")])];
      const out = removeFromSlot(blocks, "ifA", 0, "zzz");
      expect(out[0].slots?.[0].map(b => b.id)).toEqual(["t1"]);
    });
  });

  describe("moveWithinSlot", () => {
    it("reorders within slot", () => {
      const blocks = [iff("ifA", [cmd("a"), cmd("b"), cmd("c")])];
      const out = moveWithinSlot(blocks, "ifA", 0, "c", 0);
      expect(out[0].slots?.[0].map(b => b.id)).toEqual(["c", "a", "b"]);
    });
  });

  describe("locateBlock", () => {
    it("locates at root with index", () => {
      const blocks = [cmd("a"), cmd("b"), cmd("c")];
      expect(locateBlock(blocks, "b")).toEqual({ index: 1 });
    });

    it("locates inside a slot", () => {
      const blocks = [cmd("a"), iff("ifA", [cmd("t1"), cmd("t2")])];
      expect(locateBlock(blocks, "t2")).toEqual({ parentId: "ifA", slot: 0, index: 1 });
    });

    it("locates nested 2 levels deep", () => {
      const blocks = [iff("outer", [iff("inner", [cmd("x")])])];
      expect(locateBlock(blocks, "x")).toEqual({ parentId: "inner", slot: 0, index: 0 });
    });

    it("returns null when missing", () => {
      expect(locateBlock([cmd("a")], "zzz")).toBeNull();
    });
  });

  // `dest.index` se interpreta después de remover el bloque de su origen —
  // mismo contrato que el hit-test del DOM (que excluye el bloque arrastrado).
  describe("moveBlockTo", () => {
    it("reordena en la raíz hacia adelante (i → j)", () => {
      const blocks = [cmd("a"), cmd("b"), cmd("c"), cmd("d")];
      const out = moveBlockTo(blocks, "a", { index: 2 });
      expect(out.map(b => b.id)).toEqual(["b", "c", "a", "d"]);
    });

    it("reordena en la raíz hacia atrás (j → i)", () => {
      const blocks = [cmd("a"), cmd("b"), cmd("c"), cmd("d")];
      const out = moveBlockTo(blocks, "d", { index: 0 });
      expect(out.map(b => b.id)).toEqual(["d", "a", "b", "c"]);
    });

    it("mueve de raíz a slot then de un if", () => {
      const blocks = [cmd("a"), iff("ifA", [cmd("t1")])];
      const out = moveBlockTo(blocks, "a", { parentId: "ifA", slot: 0, index: 1 });
      expect(out.map(b => b.id)).toEqual(["ifA"]);
      expect(out[0].slots?.[0].map(b => b.id)).toEqual(["t1", "a"]);
    });

    it("mueve de raíz a slot else vacío", () => {
      const blocks = [cmd("a"), iff("ifA", [cmd("t1")])];
      const out = moveBlockTo(blocks, "a", { parentId: "ifA", slot: 1, index: 0 });
      expect(out[0].slots?.[1].map(b => b.id)).toEqual(["a"]);
    });

    it("saca de un slot a la raíz", () => {
      const blocks = [iff("ifA", [cmd("t1"), cmd("t2")]), cmd("z")];
      const out = moveBlockTo(blocks, "t1", { index: 2 });
      expect(out.map(b => b.id)).toEqual(["ifA", "z", "t1"]);
      expect(out[0].slots?.[0].map(b => b.id)).toEqual(["t2"]);
    });

    it("mueve entre slots de distintos parents", () => {
      const blocks = [iff("ifA", [cmd("t1")]), iff("ifB", [], [cmd("e1")])];
      const out = moveBlockTo(blocks, "t1", { parentId: "ifB", slot: 1, index: 0 });
      expect(out[0].slots?.[0]).toEqual([]);
      expect(out[1].slots?.[1].map(b => b.id)).toEqual(["t1", "e1"]);
    });

    it("mueve entre slots del mismo parent (then → else)", () => {
      const blocks = [iff("ifA", [cmd("t1"), cmd("t2")], [cmd("e1")])];
      const out = moveBlockTo(blocks, "t2", { parentId: "ifA", slot: 1, index: 1 });
      expect(out[0].slots?.[0].map(b => b.id)).toEqual(["t1"]);
      expect(out[0].slots?.[1].map(b => b.id)).toEqual(["e1", "t2"]);
    });

    it("reordena dentro del mismo slot", () => {
      const blocks = [iff("ifA", [cmd("t1"), cmd("t2"), cmd("t3")])];
      const out = moveBlockTo(blocks, "t3", { parentId: "ifA", slot: 0, index: 0 });
      expect(out[0].slots?.[0].map(b => b.id)).toEqual(["t3", "t1", "t2"]);
    });

    it("mueve un logic block completo (con sus hijos) en la raíz", () => {
      const blocks = [iff("ifA", [cmd("t1")]), cmd("a"), cmd("b")];
      const out = moveBlockTo(blocks, "ifA", { index: 2 });
      expect(out.map(b => b.id)).toEqual(["a", "b", "ifA"]);
      expect(out[2].slots?.[0].map(b => b.id)).toEqual(["t1"]);
    });

    it("mueve un logic block dentro del slot de otro logic block", () => {
      const blocks = [iff("ifA", [cmd("t1")]), iff("ifB", [])];
      const out = moveBlockTo(blocks, "ifA", { parentId: "ifB", slot: 0, index: 0 });
      expect(out.map(b => b.id)).toEqual(["ifB"]);
      expect(out[0].slots?.[0].map(b => b.id)).toEqual(["ifA"]);
      expect(out[0].slots?.[0][0].slots?.[0].map(b => b.id)).toEqual(["t1"]);
    });

    it("no-op: soltar dentro de sí mismo", () => {
      const blocks = [iff("ifA", [cmd("t1")])];
      const out = moveBlockTo(blocks, "ifA", { parentId: "ifA", slot: 0, index: 0 });
      expect(out).toBe(blocks);
    });

    it("no-op: soltar dentro de un descendiente (ciclo)", () => {
      const blocks = [iff("outer", [iff("inner", [])])];
      const out = moveBlockTo(blocks, "outer", { parentId: "inner", slot: 0, index: 0 });
      expect(out).toBe(blocks);
    });

    it("no-op: misma posición devuelve el array original (identidad)", () => {
      const blocks = [cmd("a"), cmd("b")];
      expect(moveBlockTo(blocks, "a", { index: 0 })).toBe(blocks);
      expect(moveBlockTo(blocks, "b", { index: 1 })).toBe(blocks);
    });

    it("no-op: bloque inexistente o parent inexistente", () => {
      const blocks = [cmd("a"), iff("ifA", [])];
      expect(moveBlockTo(blocks, "zzz", { index: 0 })).toBe(blocks);
      expect(moveBlockTo(blocks, "a", { parentId: "nope", slot: 0, index: 0 })).toBe(blocks);
    });

    it("clampea índices fuera de rango", () => {
      const blocks = [cmd("a"), cmd("b")];
      const out = moveBlockTo(blocks, "a", { index: 99 });
      expect(out.map(b => b.id)).toEqual(["b", "a"]);
    });

    it("preserva identidad de bloques no tocados", () => {
      const sibling = cmd("sib");
      const blocks = [sibling, cmd("a"), iff("ifA", [cmd("t1")])];
      const out = moveBlockTo(blocks, "a", { parentId: "ifA", slot: 0, index: 0 });
      expect(out[0]).toBe(sibling);
    });
  });

  describe("updateBlockById", () => {
    it("updates nested block meta", () => {
      const blocks = [iff("ifA", [cmd("inner")])];
      const out = updateBlockById(blocks, "inner", b => ({
        ...b, meta: { ...b.meta, status: "ok" },
      }));
      const inner = out[0].slots?.[0][0];
      expect(inner?.meta.status).toBe("ok");
    });

    it("preserves identity of siblings of the updated block", () => {
      const sibling = cmd("sib");
      const blocks = [iff("ifA", [cmd("inner"), sibling])];
      const out = updateBlockById(blocks, "inner", b => ({
        ...b, meta: { ...b.meta, status: "ok" },
      }));
      expect(out[0].slots?.[0][1]).toBe(sibling);
    });
  });
});
