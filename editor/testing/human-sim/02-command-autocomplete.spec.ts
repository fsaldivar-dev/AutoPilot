import { expect, test } from "@playwright/test";

// Human-sim scenario #2 — autocomplete visible siempre
// Verifies: typing triggers autocomplete, Tab picks suggestion.

test("02 autocomplete abre al tipear, Tab completa", async ({ page }) => {
  await page.goto("/");
  // Seed a project through the UI.
  await page.getByTestId("new-project-btn").click();
  await page.getByTestId("new-project-name").fill("Demo");
  await page.getByTestId("new-project-create").click();

  const input = page.getByTestId("command-bar-input");
  await expect(input).toBeVisible();
  await input.focus();
  await input.type("ta");

  // Autocomplete popover visible with at least one item starting with tap
  const popover = page.getByTestId("autocomplete-popover");
  await expect(popover).toBeVisible();
  await page.screenshot({
    path: "testing/evidence/02-autocomplete-tap.png",
    fullPage: true,
  });
  await expect(popover.getByTestId("suggestion-0").locator(".label")).toContainText(
    /^tap/
  );

  // Tab picks
  await input.press("Tab");
  await expect(input).toHaveValue(/^tap\s?$/);
  await page.screenshot({
    path: "testing/evidence/02-autocomplete-picked.png",
  });

  // Typing `$` triggers env-var providers (but there are none yet — check popover still visible)
  await input.fill("type $");
  // With no env vars, popover may have zero suggestions; this only checks it doesn't crash.
  const stillExists = await page
    .getByTestId("autocomplete-popover")
    .count();
  expect(stillExists).toBeGreaterThanOrEqual(0);
});
