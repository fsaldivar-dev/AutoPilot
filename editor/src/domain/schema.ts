// Zod runtime schemas for validation at the DB / IPC boundary.

import { z } from "zod";

export const PlatformSchema = z.enum(["ios", "android", "both"]);

export const BlockStatusSchema = z.enum(["idle", "running", "ok", "err"]);

export const BlockMetaSchema = z.object({
  status: BlockStatusSchema,
  ms: z.number().optional(),
  error: z.string().optional(),
  ranAt: z.number().optional(),
  screenshotId: z.string().optional(),
});

export const ParamSchema = z.object({
  name: z.string(),
  type: z.enum(["string", "number", "element", "boolean", "enum"]),
  secure: z.boolean().optional(),
  default: z.string().optional(),
  enumValues: z.array(z.string()).optional(),
});

export const BlockSchema: z.ZodType<import("./types").Block> = z.lazy(() =>
  z.object({
    id: z.string(),
    kind: z.enum(["command", "component", "logic", "comment"]),
    command: z.string().optional(),
    args: z.record(z.string(), z.union([z.string(), z.number(), z.boolean()])).optional(),
    slots: z.array(z.array(BlockSchema)).optional(),
    logicKind: z.enum(["if", "else", "repeat", "try", "catch", "foreach"]).optional(),
    meta: BlockMetaSchema,
  })
);

export const FlowSchema = z.object({
  id: z.string(),
  projectId: z.string(),
  name: z.string(),
  blocks: z.array(BlockSchema),
  entryBlockId: z.string().optional(),
  updatedAt: z.number(),
});

export const ComponentSchema = z.object({
  id: z.string(),
  projectId: z.string(),
  name: z.string(),
  signature: z.array(ParamSchema),
  returnType: z.string().optional(),
  body: z.array(BlockSchema),
  usageCount: z.number(),
  createdFromFlowId: z.string().optional(),
});

export const EnvVarSchema = z.object({
  projectId: z.string(),
  scope: z.string(),
  key: z.string(),
  value: z.string(),
  secret: z.boolean(),
});

export const DeviceRefSchema = z.object({
  id: z.string(),
  platform: PlatformSchema,
  name: z.string(),
  udid: z.string().optional(),
});

export const ProjectSchema = z.object({
  id: z.string(),
  name: z.string(),
  platform: PlatformSchema,
  flows: z.array(FlowSchema),
  components: z.array(ComponentSchema),
  env: z.array(EnvVarSchema),
  devices: z.array(DeviceRefSchema),
  createdAt: z.number(),
  updatedAt: z.number(),
});

export const FrameSchema = z.object({
  ok: z.boolean(),
  ms: z.number().optional(),
  out: z.string().optional(),
  err: z.string().optional(),
  ready: z.boolean().optional(),
  bye: z.boolean().optional(),
  skip: z.boolean().optional(),
  platform: z.string().optional(),
});
