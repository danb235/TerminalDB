import { expect, test } from "@playwright/test";

test("keeps a branded recovery shell visible when the app bundle cannot start", async ({ page }) => {
  await page.route("**/src/main.tsx", (route) => route.abort("failed"));
  await page.goto("/");

  await expect(page.getByRole("heading", { name: "Opening TerminalDB" })).toBeVisible();
  await expect(page.getByText("Loading your devices and terminal sessions securely."))
    .toBeVisible();
  await expect(page.locator("body")).not.toHaveText("");
});
