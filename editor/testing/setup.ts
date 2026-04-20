import "@testing-library/jest-dom/vitest";
import { afterEach, vi } from "vitest";
import { cleanup } from "@testing-library/react";

// Mock Tauri APIs — tests run in jsdom without a real Tauri runtime.
vi.mock("@tauri-apps/api/core", () => ({
  invoke: vi.fn(async () => null),
}));

vi.mock("@tauri-apps/api/event", () => ({
  listen: vi.fn(async () => () => {}),
  emit: vi.fn(async () => {}),
}));

afterEach(() => {
  cleanup();
});
