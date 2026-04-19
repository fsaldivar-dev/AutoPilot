import { expect, test } from "@playwright/test";

// Human-sim scenario #1 — first launch
// Verifies: empty state, project creation, flow auto-creation.

test("01 primer arranque: empty state + crear proyecto", async ({ page }) => {
  await page.goto("/");

  // Empty state
  await expect(page.getByText(/Sin proyectos/i)).toBeVisible();
  await expect(page.getByTestId("toolbar")).toBeVisible();
  await page.screenshot({
    path: "testing/evidence/01-empty-state.png",
    fullPage: true,
  });

  // Create a project
  await page.getByTestId("new-project-btn").click();
  const nameInput = page.getByTestId("new-project-name");
  await expect(nameInput).toBeVisible();
  await nameInput.fill("Banco Atlas");
  await page.screenshot({ path: "testing/evidence/01-new-project-modal.png" });
  await page.getByTestId("new-project-create").click();

  // Project + flow created
  await expect(page.getByTestId("current-flow-label")).toHaveText("Happy path");
  await expect(page.locator('[data-testid^="project-"]').first()).toContainText(
    "Banco Atlas"
  );
  await page.screenshot({
    path: "testing/evidence/01-project-created.png",
    fullPage: true,
  });
});
