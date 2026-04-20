import { expect, test } from "@playwright/test";

test("05 share export JSON strips secretos", async ({ page }) => {
  await page.goto("/");
  await page.getByTestId("new-project-btn").click();
  await page.getByTestId("new-project-name").fill("ShareDemo");
  await page.getByTestId("new-project-create").click();

  // Seed secret env var
  await page.getByTestId("env-add-btn").click();
  await page.getByTestId("env-key-input").fill("apiKey");
  await page.getByTestId("env-value-input").fill("REAL_SECRET");
  await page.locator('input[type="checkbox"]').check();
  await page.getByTestId("env-save-btn").click();

  await page.getByTestId("share-btn").click();
  await expect(page.getByTestId("share-modal")).toBeVisible();

  const preview = page.getByTestId("share-preview");
  const text = await preview.textContent();
  // JSON preview must not contain the actual secret.
  expect(text).not.toContain("REAL_SECRET");
  // But should mention the key name.
  expect(text).toContain("apiKey");
  await page.screenshot({
    path: "testing/evidence/05-share-modal.png",
    fullPage: true,
  });
});
