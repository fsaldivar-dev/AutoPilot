import { expect, test } from "@playwright/test";

// Human-sim scenario #3 — group as component
// Seeds 3 command blocks directly via window.__appStore__ (exposed in dev mode),
// then uses the UI to select + group + verify component appears.

test("03 agrupar como componente detecta parametros", async ({ page }) => {
  await page.goto("/");

  // Create project through UI
  await page.getByTestId("new-project-btn").click();
  await page.getByTestId("new-project-name").fill("Demo");
  await page.getByTestId("new-project-create").click();

  // Seed blocks via window.__store__ (we expose it in dev mode).
  await page.evaluate(() => {
    type W = typeof window & { __store__?: { getState: () => any } };
    const w = window as W;
    if (!w.__store__) throw new Error("store not exposed");
    const store = w.__store__.getState();
    const project = store.projects[0];
    const flow = project.flows[0];
    const now = Date.now();
    store.appendBlock(flow.id, {
      id: "b1",
      kind: "command",
      command: 'tap "Login"',
      args: {},
      meta: { status: "ok", ms: 120, ranAt: now },
    });
    store.appendBlock(flow.id, {
      id: "b2",
      kind: "command",
      command: "type $user.email",
      args: {},
      meta: { status: "ok", ms: 450, ranAt: now },
    });
    store.appendBlock(flow.id, {
      id: "b3",
      kind: "command",
      command: "type $user.password",
      args: {},
      meta: { status: "ok", ms: 520, ranAt: now },
    });
  });

  // Select all 3 blocks
  await page.getByTestId("block-b1").click();
  await page.getByTestId("block-b2").click({ modifiers: ["Meta"] });
  await page.getByTestId("block-b3").click({ modifiers: ["Meta"] });

  await expect(page.getByTestId("group-toolbar")).toBeVisible();
  await page.screenshot({
    path: "testing/evidence/03-group-selected.png",
    fullPage: true,
  });

  await page.getByTestId("group-as-component-btn").click();

  // Modal should show 2 detected params.
  await expect(page.getByTestId("group-modal")).toBeVisible();
  await expect(page.getByTestId("detected-param-user.email")).toBeVisible();
  await expect(page.getByTestId("detected-param-user.password")).toBeVisible();
  await page.getByTestId("component-name-input").fill("LoginFlow");
  await page.screenshot({
    path: "testing/evidence/03-group-modal.png",
    fullPage: true,
  });
  await page.getByTestId("group-create-btn").click();

  // Component library now shows LoginFlow.
  await expect(page.getByTestId("component-library")).toContainText("LoginFlow");
  await page.screenshot({
    path: "testing/evidence/03-component-created.png",
    fullPage: true,
  });
});
