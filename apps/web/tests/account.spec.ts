import { expect, test, type Page } from "@playwright/test";

const accountConfiguration = {
  clientId: "qa-client",
  domain: "https://auth.example.invalid",
  issuer: "https://cognito-idp.us-west-2.amazonaws.com/us-west-2_QA",
  callbackPath: "/auth/callback",
};

async function mockAccountPage(
  page: Page,
  devices: readonly Record<string, unknown>[],
): Promise<void> {
  await page.addInitScript(() => {
    localStorage.setItem("terminaldb.account.tokens.v1", JSON.stringify({
      accessToken: "qa-access-token",
      refreshToken: "qa-refresh-token",
      expiresAt: Date.now() + 60 * 60 * 1_000,
    }));
  });
  await page.route("**/api/config", async (route) => {
    await route.fulfill({
      contentType: "application/json",
      body: JSON.stringify({
        apiBaseUrl: "",
        websocketUrl: "/socket",
        protocolVersion: 1,
        region: "us-west-2",
        pairingEnabled: true,
        accountAuth: accountConfiguration,
        mockMode: false,
      }),
    });
  });
  await page.route("**/api/v1/account/devices", async (route) => {
    await route.fulfill({
      contentType: "application/json",
      body: JSON.stringify({ devices }),
    });
  });
  await page.goto("/?unpaired&account");
  await expect(page.getByRole("heading", { name: "Your Macs" })).toBeVisible();
}

test("keeps enrolled Macs visible with clear online and offline states", async ({ page }) => {
  const now = Math.floor(Date.now() / 1_000);
  await mockAccountPage(page, [
    {
      deviceId: "mac-online",
      deviceName: "MacBook Pro",
      registeredAt: now - 5_000,
      lastSeenAt: now,
      state: "online",
      sessionId: "session-online",
      sessionCreatedAt: now - 120,
    },
    {
      deviceId: "mac-offline",
      deviceName: "Office iMac",
      registeredAt: now - 20_000,
      lastSeenAt: now - 3_600,
      state: "offline",
    },
  ]);

  const online = page.getByRole("button", { name: /MacBook Pro/u });
  await expect(online).toContainText("Online");
  await expect(online).toContainText("Open");
  const offline = page.locator("article").filter({ hasText: "Office iMac" });
  await expect(offline).toContainText("Offline");
  await expect(offline).toContainText("Last seen 1h ago");
  await expect(page.getByText(/Terminal names and counts remain end-to-end encrypted/u))
    .toBeVisible();
});

test("allows account login when every enrolled Mac is offline", async ({ page }) => {
  const now = Math.floor(Date.now() / 1_000);
  await mockAccountPage(page, [
    {
      deviceId: "mac-studio",
      deviceName: "Mac Studio",
      registeredAt: now - 20_000,
      lastSeenAt: now - 86_400,
      state: "offline",
    },
  ]);

  await expect(page.getByText("You’re signed in. No Macs are online.")).toBeVisible();
  await expect(page.getByText(/Open TerminalDB on an enrolled Mac/u)).toBeVisible();
  await expect(page.getByRole("button", { name: "Log out" })).toBeEnabled();
  await expect(page.getByRole("button", { name: "Add a Mac" })).toBeEnabled();
});

test("prepares account creators for mandatory authenticator-app setup", async ({ page }) => {
  await page.route("**/api/config", async (route) => {
    await route.fulfill({
      contentType: "application/json",
      body: JSON.stringify({
        apiBaseUrl: "",
        websocketUrl: "/socket",
        protocolVersion: 1,
        region: "us-west-2",
        pairingEnabled: true,
        accountAuth: accountConfiguration,
        mockMode: false,
      }),
    });
  });
  await page.goto("/?unpaired&account=create#account-bootstrap=qa-approved-bootstrap");

  await expect(page.getByRole("heading", { name: "Create your TerminalDB account" }))
    .toBeVisible();
  await expect(page.getByText("Authenticator app required")).toBeVisible();
  await expect(page.getByText(/Cognito will show a QR code/u)).toBeVisible();
  await expect(page.getByText(/There is no email, SMS, passkey, or backup-code alternative/u))
    .toBeVisible();
  await expect(page.getByRole("button", { name: "Create account & set up authenticator" }))
    .toBeVisible();
});
