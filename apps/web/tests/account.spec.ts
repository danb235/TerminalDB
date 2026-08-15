import { expect, test, type Page } from "@playwright/test";

const accountConfiguration = {
  clientId: "qa-client",
  domain: "https://auth.example.invalid",
  issuer: "https://cognito-idp.us-west-2.amazonaws.com/us-west-2_QA",
  callbackPath: "/auth/callback",
};

function freshAccessToken(label: string): string {
  const claims = btoa(JSON.stringify({ iat: Math.floor(Date.now() / 1_000) }))
    .replace(/\+/gu, "-")
    .replace(/\//gu, "_")
    .replace(/=+$/gu, "");
  return `${label}.${claims}.signature`;
}

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
  await expect(page.getByRole("heading", { name: "Devices & sessions" })).toBeVisible();
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

test("explains the Mac-approved account workflow from the marketing site", async ({ page }) => {
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
  await page.goto("/?unpaired&account=create&source=marketing");

  await expect(page.getByRole("heading", { name: "Create your account from TerminalDB" }))
    .toBeVisible();
  await expect(page.getByText(/website cannot create an account and claim access/u))
    .toBeVisible();
  await expect(page.getByRole("link", { name: "Download TerminalDB for macOS" }))
    .toHaveAttribute("href", /TerminalDB-macOS\.zip$/u);
  await expect(page.getByRole("button", { name: "Already have an account? Log in" }))
    .toBeEnabled();
});

test("reports signed-in status to the marketing origin without sharing tokens", async ({ page }) => {
  const username = "marketing-qa-user";
  const claims = btoa(JSON.stringify({ username, iat: Math.floor(Date.now() / 1_000) }))
    .replace(/\+/gu, "-")
    .replace(/\//gu, "_")
    .replace(/=+$/gu, "");
  const accessToken = `header.${claims}.signature`;
  await page.addInitScript(({ token }) => {
    localStorage.setItem("terminaldb.account.tokens.v1", JSON.stringify({
      accessToken: token,
      refreshToken: "bridge-refresh-token",
      expiresAt: Date.now() + 60 * 60 * 1_000,
    }));
  }, { token: accessToken });
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
  await page.goto("/?unpaired");

  const status = await page.evaluate(() => new Promise<Record<string, unknown>>((resolve) => {
    const frame = document.createElement("iframe");
    const timeout = window.setTimeout(() => resolve({ timeout: true }), 5_000);
    window.addEventListener("message", (event) => {
      if (event.data?.type === "terminaldb-account-status-v1") {
        window.clearTimeout(timeout);
        resolve(event.data);
      }
    }, { once: true });
    frame.addEventListener("load", () => {
      frame.contentWindow?.postMessage(
        { type: "terminaldb-account-status-request-v1" },
        location.origin,
      );
    });
    frame.src = "/auth-status.html";
    document.body.append(frame);
  }));
  expect(status).toEqual({
    type: "terminaldb-account-status-v1",
    signedIn: true,
    username,
  });
  expect(JSON.stringify(status)).not.toContain(accessToken);
  expect(JSON.stringify(status)).not.toContain("bridge-refresh-token");
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
  await expect(page.getByRole("button", { name: "Change password" })).toBeEnabled();
  await expect(page.getByText(/choose Connect Account/u)).toBeVisible();
});

test("prepares account creators for mandatory authenticator-app setup", async ({ page }) => {
  let canceledBootstrap: string | undefined;
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
  await page.route("**/api/v1/account-bootstrap", async (route) => {
    const body = route.request().postDataJSON() as { bootstrapToken?: string };
    canceledBootstrap = body.bootstrapToken;
    await route.fulfill({ contentType: "application/json", body: JSON.stringify({ canceled: true }) });
  });
  await page.route("https://cognito-idp.us-west-2.amazonaws.com/**", async (route) => {
    const target = route.request().headers()["x-amz-target"];
    const responses: Record<string, Record<string, unknown>> = {
      "AWSCognitoIdentityProviderService.SignUp": {},
      "AWSCognitoIdentityProviderService.InitiateAuth": {
        ChallengeName: "MFA_SETUP",
        Session: "qa-password-session",
      },
      "AWSCognitoIdentityProviderService.AssociateSoftwareToken": {
        SecretCode: "JBSWY3DPEHPK3PXP",
        Session: "qa-totp-session",
      },
    };
    await route.fulfill({
      contentType: "application/json",
      body: JSON.stringify(responses[target ?? ""] ?? {}),
    });
  });
  await page.goto("/?unpaired&account=create#account-bootstrap=qa-approved-bootstrap");

  await expect(page.getByRole("heading", { name: "Create your TerminalDB account" }))
    .toBeVisible();
  await expect(page.getByText("Authenticator app required")).toBeVisible();
  await expect(page.getByText(/scan a QR code or copy the setup key/u)).toBeVisible();
  await expect(page.getByText(/There is no email, SMS, or backup-code fallback/u)).toBeVisible();
  await page.getByRole("button", { name: "Create account", exact: true }).click();
  await expect(page.getByRole("heading", { name: "Choose your credentials" })).toBeVisible();
  await page.getByLabel("Username").fill("qa-new-user");
  await page.getByLabel("Password", { exact: true }).fill("Unique-Password-42!");
  await page.getByLabel("Confirm password").fill("Unique-Password-42!");
  await page.getByRole("button", { name: "Continue to authenticator setup" }).click();

  await expect(page.getByRole("heading", { name: "Secure your account" })).toBeVisible();
  await expect(page.getByRole("img", { name: "TerminalDB authenticator QR code" })).toBeVisible();
  await expect(page.getByLabel("Authenticator setup key")).toContainText("JBSW Y3DP EHPK 3PXP");
  await page.getByRole("button", { name: "Copy setup key" }).click();
  await expect(page.getByRole("status")).toHaveText("Setup key copied.");
  const setup = await page.locator(".account-totp-setup").boundingBox();
  const enrollment = await page.locator(".account-totp-enrollment").boundingBox();
  const qr = await page.locator(".account-totp-qr").boundingBox();
  const key = await page.locator(".account-totp-key").boundingBox();
  expect(setup).not.toBeNull();
  expect(enrollment).not.toBeNull();
  expect(qr).not.toBeNull();
  expect(key).not.toBeNull();
  expect(Math.abs((setup!.x + setup!.width / 2) - (enrollment!.x + enrollment!.width / 2)))
    .toBeLessThan(2);
  if ((page.viewportSize()?.width ?? 0) >= 600) {
    expect(Math.abs(qr!.y - key!.y)).toBeLessThan(2);
    expect(await page.evaluate(() => document.documentElement.scrollHeight <= innerHeight + 1))
      .toBe(true);
  } else {
    expect(qr!.y + qr!.height).toBeLessThanOrEqual(key!.y);
  }

  await page.getByRole("button", { name: "Cancel setup" }).click();
  await expect(page.getByRole("heading", { name: "Sign in to TerminalDB" })).toBeVisible();
  await expect(page.getByRole("button", { name: "Sign in", exact: true })).toBeEnabled();
  expect(canceledBootstrap).toBe("qa-approved-bootstrap");
});

test("keeps password and TOTP sign-in inside TerminalDB", async ({ page }) => {
  const directAccessToken = freshAccessToken("direct-signin-access");
  const externalAuthRequests: string[] = [];
  page.on("request", (request) => {
    if (request.url().startsWith(accountConfiguration.domain)) {
      externalAuthRequests.push(request.url());
    }
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
  await page.route("https://cognito-idp.us-west-2.amazonaws.com/**", async (route) => {
    const target = route.request().headers()["x-amz-target"];
    const responses: Record<string, Record<string, unknown>> = {
      "AWSCognitoIdentityProviderService.InitiateAuth": {
        ChallengeName: "SOFTWARE_TOKEN_MFA",
        Session: "qa-signin-session",
      },
      "AWSCognitoIdentityProviderService.RespondToAuthChallenge": {
        AuthenticationResult: {
          AccessToken: directAccessToken,
          RefreshToken: "qa-signin-refresh",
          ExpiresIn: 3_600,
        },
      },
    };
    await route.fulfill({
      contentType: "application/json",
      body: JSON.stringify(responses[target ?? ""] ?? {}),
    });
  });
  await page.route("**/api/v1/account/devices", async (route) => {
    await route.fulfill({ contentType: "application/json", body: JSON.stringify({ devices: [] }) });
  });

  await page.goto("/?unpaired&account");
  await page.getByRole("button", { name: "Sign in", exact: true }).click();
  await page.getByLabel("Username").fill("returning-user");
  await page.getByLabel("Password", { exact: true }).fill("Unique-Password-42!");
  await page.getByRole("button", { name: "Continue" }).click();
  await expect(page.getByRole("heading", { name: "Enter your authenticator code" }))
    .toBeVisible();
  await page.getByLabel("Six-digit code").fill("123456");
  await page.getByRole("button", { name: "Sign in", exact: true }).click();

  await expect(page.getByRole("heading", { name: "Devices & sessions" })).toBeVisible();
  expect(new URL(page.url()).origin).not.toBe(accountConfiguration.domain);
  expect(externalAuthRequests).toEqual([]);
  expect(JSON.parse(await page.evaluate(() =>
    localStorage.getItem("terminaldb.account.tokens.v1") ?? "{}"
  ))).toMatchObject({
    accessToken: directAccessToken,
    refreshMode: "cognito",
  });
});

test("offers Mac-approved recovery after a rejected sign-in", async ({ page }) => {
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
  await page.route("https://cognito-idp.us-west-2.amazonaws.com/**", async (route) => {
    await route.fulfill({
      status: 400,
      contentType: "application/json",
      body: JSON.stringify({ __type: "NotAuthorizedException" }),
    });
  });

  await page.goto("/?unpaired&account");
  await page.getByRole("button", { name: "Sign in", exact: true }).click();
  await page.getByLabel("Username").fill("unknown-or-locked");
  await page.getByLabel("Password", { exact: true }).fill("Not-Accepted-42!");
  await page.getByRole("button", { name: "Continue" }).click();

  await expect(page.getByRole("alert")).toContainText("Sign-in was not accepted");
  await expect(page.getByRole("button", { name: "Reset password from an enrolled Mac" }))
    .toBeEnabled();
  await expect(page.getByRole("alert")).toContainText("New here?");
  const securePasswordSelection = await page.getByLabel("Password", { exact: true }).evaluate(
    (element) => getComputedStyle(element, "::selection").webkitTextFillColor,
  );
  expect(securePasswordSelection).toBe("rgba(0, 0, 0, 0)");
});

test("uses a one-time Mac approval to reset password and require existing TOTP", async ({ page }) => {
  const directAccessToken = freshAccessToken("reset-access");
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
  await page.route("**/api/v1/account-password-reset/redeem", async (route) => {
    await route.fulfill({
      contentType: "application/json",
      body: JSON.stringify({
        username: "returning-user",
        temporaryPassword: "server-temporary-value",
      }),
    });
  });
  await page.route("https://cognito-idp.us-west-2.amazonaws.com/**", async (route) => {
    const target = route.request().headers()["x-amz-target"];
    const body = route.request().postDataJSON() as { ChallengeName?: string };
    const response = target === "AWSCognitoIdentityProviderService.InitiateAuth"
      ? { ChallengeName: "NEW_PASSWORD_REQUIRED", Session: "new-password-session" }
      : body.ChallengeName === "NEW_PASSWORD_REQUIRED"
        ? { ChallengeName: "SOFTWARE_TOKEN_MFA", Session: "reset-totp-session" }
        : {
            AuthenticationResult: {
              AccessToken: directAccessToken,
              RefreshToken: "reset-refresh",
              ExpiresIn: 3_600,
            },
          };
    await route.fulfill({ contentType: "application/json", body: JSON.stringify(response) });
  });
  await page.route("**/api/v1/account/devices", async (route) => {
    await route.fulfill({ contentType: "application/json", body: JSON.stringify({ devices: [] }) });
  });

  await page.goto("/?unpaired&account=reset-password#account-password-reset=mac-approved-reset");
  await expect(page.getByRole("heading", { name: "Choose a new password" })).toBeVisible();
  await page.getByLabel("New password", { exact: true }).fill("Replacement-Value-42!");
  await page.getByLabel("Confirm new password").fill("Replacement-Value-42!");
  await page.getByRole("button", { name: "Continue to authenticator" }).click();
  await expect(page.getByRole("heading", { name: "Confirm with your authenticator" })).toBeVisible();
  await page.getByLabel("Six-digit code").fill("123456");
  await page.getByRole("button", { name: "Finish password reset" }).click();
  await expect(page.getByRole("heading", { name: "Devices & sessions" })).toBeVisible();
  expect(page.url()).not.toContain("account-password-reset");
});

test("recovers incomplete accounts without opening Cognito's hosted MFA page", async ({ page }) => {
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
  await page.route("https://cognito-idp.us-west-2.amazonaws.com/**", async (route) => {
    await route.fulfill({
      contentType: "application/json",
      body: JSON.stringify({ ChallengeName: "MFA_SETUP", Session: "unfinished-session" }),
    });
  });

  await page.goto("/?unpaired&account");
  await page.getByRole("button", { name: "Sign in", exact: true }).click();
  await page.getByLabel("Username").fill("unfinished-user");
  await page.getByLabel("Password", { exact: true }).fill("Unique-Password-42!");
  await page.getByRole("button", { name: "Continue" }).click();

  await expect(page.getByRole("alert")).toContainText("copyable setup key");
  await expect(page).toHaveURL(/\?unpaired&account$/u);
});

test("completes first-party TOTP enrollment and connects the approved Mac", async ({ page }) => {
  const directAccessToken = freshAccessToken("direct-signup-access");
  let completedAuthorization: string | undefined;
  let completedBootstrap: string | undefined;
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
  await page.route("https://cognito-idp.us-west-2.amazonaws.com/**", async (route) => {
    const target = route.request().headers()["x-amz-target"];
    const responses: Record<string, Record<string, unknown>> = {
      "AWSCognitoIdentityProviderService.SignUp": {},
      "AWSCognitoIdentityProviderService.InitiateAuth": {
        ChallengeName: "MFA_SETUP",
        Session: "qa-password-session",
      },
      "AWSCognitoIdentityProviderService.AssociateSoftwareToken": {
        SecretCode: "JBSWY3DPEHPK3PXP",
        Session: "qa-totp-session",
      },
      "AWSCognitoIdentityProviderService.VerifySoftwareToken": {
        Status: "SUCCESS",
        Session: "qa-verified-session",
      },
      "AWSCognitoIdentityProviderService.RespondToAuthChallenge": {
        AuthenticationResult: {
          AccessToken: directAccessToken,
          RefreshToken: "qa-direct-refresh",
          ExpiresIn: 3_600,
        },
      },
    };
    await route.fulfill({
      contentType: "application/json",
      body: JSON.stringify(responses[target ?? ""] ?? {}),
    });
  });
  await page.route("**/api/v1/account/bootstrap/complete", async (route) => {
    completedAuthorization = route.request().headers().authorization;
    completedBootstrap = (route.request().postDataJSON() as { bootstrapToken?: string }).bootstrapToken;
    await route.fulfill({
      contentType: "application/json",
      body: JSON.stringify({ completed: true, deviceId: "qa-mac" }),
    });
  });
  await page.route("**/api/v1/account/devices", async (route) => {
    await route.fulfill({ contentType: "application/json", body: JSON.stringify({ devices: [] }) });
  });
  await page.goto("/?unpaired&account=create#account-bootstrap=qa-approved-bootstrap");
  await page.getByRole("button", { name: "Create account", exact: true }).click();
  await page.getByLabel("Username").fill("qa-new-user");
  await page.getByLabel("Password", { exact: true }).fill("Unique-Password-42!");
  await page.getByLabel("Confirm password").fill("Unique-Password-42!");
  await page.getByRole("button", { name: "Continue to authenticator setup" }).click();
  await page.getByLabel("Six-digit code").fill("123456");
  await page.getByRole("button", { name: "Finish account setup" }).click();

  await expect(page.getByRole("heading", { name: "Devices & sessions" })).toBeVisible();
  await expect(page.getByText(/Mac enrolled/u)).toBeVisible();
  await expect.poll(() => completedAuthorization).toBe(`Bearer ${directAccessToken}`);
  expect(completedBootstrap).toBe("qa-approved-bootstrap");
  expect(JSON.parse(await page.evaluate(() =>
    localStorage.getItem("terminaldb.account.tokens.v1") ?? "{}"
  ))).toMatchObject({
    accessToken: directAccessToken,
    refreshMode: "cognito",
  });
});

test("connects an existing account from a Mac without an enrollment code", async ({ page }) => {
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
  await page.goto("/?unpaired&account=connect#account-bootstrap=qa-connect-bootstrap");

  await expect(page.getByRole("heading", { name: "Connect this Mac" })).toBeVisible();
  await expect(page.getByText(/one-time Mac approval expires automatically/u)).toBeVisible();
  await expect(page.getByRole("button", { name: "Sign in & connect this Mac" }))
    .toBeVisible();
  await expect(page.getByText(/enrollment code/u)).toHaveCount(0);
});

test("changes the password through Cognito after recent account authentication", async ({ page }) => {
  const accessToken = freshAccessToken("password-access");
  let passwordRequest: Record<string, unknown> | undefined;
  let finalizedWith: string | undefined;
  await page.addInitScript((token) => {
    localStorage.setItem("terminaldb.account.tokens.v1", JSON.stringify({
      accessToken: token,
      refreshToken: "qa-refresh-token",
      expiresAt: Date.now() + 60 * 60 * 1_000,
    }));
  }, accessToken);
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
    await route.fulfill({ contentType: "application/json", body: JSON.stringify({ devices: [] }) });
  });
  await page.route("https://cognito-idp.us-west-2.amazonaws.com/**", async (route) => {
    passwordRequest = route.request().postDataJSON() as Record<string, unknown>;
    expect(route.request().headers()["x-amz-target"])
      .toBe("AWSCognitoIdentityProviderService.ChangePassword");
    await route.fulfill({ status: 200, contentType: "application/json", body: "{}" });
  });
  await page.route("**/api/v1/account/security/password-changed", async (route) => {
    finalizedWith = route.request().headers().authorization;
    await route.fulfill({ status: 204, body: "" });
  });
  await page.route("https://auth.example.invalid/oauth2/revoke", async (route) => {
    await route.fulfill({ status: 200, body: "" });
  });
  await page.route("https://auth.example.invalid/logout?**", async (route) => {
    await route.fulfill({ status: 200, contentType: "text/html", body: "Signed out" });
  });

  await page.goto("/?unpaired");
  await page.getByRole("button", { name: "Change password" }).click();
  await expect(page.getByRole("heading", { name: "Change your password" })).toBeVisible();
  const currentPassword = ["Current", "Strong", "42!"].join("-");
  const nextPassword = ["Next", "Strong", "84!"].join("-");
  await page.getByLabel("Current password").fill(currentPassword);
  await page.getByLabel("New password", { exact: true }).fill(nextPassword);
  await page.getByLabel("Confirm new password").fill(nextPassword);
  const logoutRequest = page.waitForRequest((request) =>
    request.url().startsWith("https://auth.example.invalid/logout?"),
  );
  await page.getByRole("button", { name: "Change password & sign out browsers" }).click();
  await logoutRequest;

  expect(passwordRequest).toMatchObject({
    AccessToken: accessToken,
    PreviousPassword: currentPassword,
    ProposedPassword: nextPassword,
  });
  expect(finalizedWith).toBe(`Bearer ${accessToken}`);
});
