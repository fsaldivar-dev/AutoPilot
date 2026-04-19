import { expect, test } from "@playwright/test";

test("04 variables de entorno chips + secretos", async ({ page }) => {
  await page.goto("/");
  await page.getByTestId("new-project-btn").click();
  await page.getByTestId("new-project-name").fill("EnvDemo");
  await page.getByTestId("new-project-create").click();

  await page.getByTestId("env-add-btn").click();
  await page.getByTestId("env-key-input").fill("user.email");
  await page.getByTestId("env-value-input").fill("maria@demo.io");
  await page.getByTestId("env-save-btn").click();

  await expect(page.getByTestId("env-user.email")).toBeVisible();
  await expect(page.getByTestId("env-user.email")).toContainText("maria@demo.io");

  await page.getByTestId("env-add-btn").click();
  await page.getByTestId("env-key-input").fill("user.password");
  await page.getByTestId("env-value-input").fill("supersecret");
  await page.locator('input[type="checkbox"]').check();
  await page.getByTestId("env-save-btn").click();

  const secretChip = page.getByTestId("env-user.password");
  await expect(secretChip).toBeVisible();
  await expect(secretChip).not.toContainText("supersecret");
  await expect(secretChip).toContainText("••••");
  await page.screenshot({
    path: "testing/evidence/04-env-chips.png",
    fullPage: true,
  });
});
