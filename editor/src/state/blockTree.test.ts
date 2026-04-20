import { describe, expect, it } from "vitest";
import type { Block } from "../domain/types";
import {
  findBlock,
  insertIntoSlot,
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
