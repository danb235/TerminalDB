import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import {
  accountAccessToken,
  accountTokenIssuedAt,
  beginAccountSignIn,
  changeAccountPassword,
  clearAccountCredentials,
  completeAccountSignIn,
  hasRecentAccountAuthentication,
  signUpWithBootstrap,
  signOutAccount,
  type AccountAuthConfiguration,
} from "./account-auth";

const configuration: AccountAuthConfiguration = {
  clientId: "web-client",
  domain: "https://login.example.invalid",
  issuer: "https://issuer.example.invalid/pool",
  callbackPath: "/auth/callback",
};

describe("Cognito account OAuth", () => {
  beforeEach(() => {
    localStorage.clear();
    sessionStorage.clear();
    history.replaceState({}, "", "/");
  });

  afterEach(() => {
    vi.restoreAllMocks();
  });

  it("exchanges a verified authorization code with its PKCE verifier", async () => {
    sessionStorage.setItem("terminaldb.account.oauth-state.v1", "expected-state");
    sessionStorage.setItem("terminaldb.account.pkce-verifier.v1", "pkce-verifier");
    history.replaceState({}, "", "/auth/callback?code=one-time-code&state=expected-state");
    const fetchMock = vi.spyOn(globalThis, "fetch").mockResolvedValue(
      new Response(JSON.stringify({
        access_token: "access-token",
        refresh_token: "refresh-token",
        expires_in: 3_600,
      }), { status: 200, headers: { "content-type": "application/json" } }),
    );

    await expect(completeAccountSignIn(configuration)).resolves.toBe(true);

    const request = fetchMock.mock.calls[0];
    expect(request?.[0]).toBe("https://login.example.invalid/oauth2/token");
    expect(String(request?.[1]?.body)).toContain("code_verifier=pkce-verifier");
    expect(String(request?.[1]?.body)).toContain("grant_type=authorization_code");
    expect(location.pathname).toBe("/");
    await expect(accountAccessToken(configuration)).resolves.toBe("access-token");
  });

  it("starts authorization code login with state and an S256 PKCE challenge", async () => {
    const navigate = vi.fn();

    await beginAccountSignIn(configuration, navigate);

    expect(navigate).toHaveBeenCalledTimes(1);
    const url = navigate.mock.calls[0]?.[0] as URL;
    expect(url.pathname).toBe("/oauth2/authorize");
    expect(url.searchParams.get("response_type")).toBe("code");
    expect(url.searchParams.get("scope")).toBe(
      "openid profile aws.cognito.signin.user.admin",
    );
    expect(url.searchParams.get("code_challenge_method")).toBe("S256");
    expect(url.searchParams.get("code_challenge")).toMatch(/^[\w-]{40,}$/u);
    expect(url.searchParams.get("state")).toBe(
      sessionStorage.getItem("terminaldb.account.oauth-state.v1"),
    );
    expect(sessionStorage.getItem("terminaldb.account.pkce-verifier.v1"))
      .toMatch(/^[\w-]{40,}$/u);
    expect(url.searchParams.has("code_verifier")).toBe(false);
  });

  it("forces a fresh Cognito ceremony for security-sensitive actions", async () => {
    const navigate = vi.fn();

    await beginAccountSignIn(configuration, navigate, {
      returnTo: "/?account=password&source=desktop",
      forceReauthentication: true,
    });

    const url = navigate.mock.calls[0]?.[0] as URL;
    expect(url.searchParams.get("prompt")).toBe("login");
    expect(sessionStorage.getItem("terminaldb.account.return-to.v1"))
      .toBe("/?account=password&source=desktop");
  });

  it("sends a Mac-approved signup directly to Cognito without email", async () => {
    const fetchMock = vi.spyOn(globalThis, "fetch").mockResolvedValue(
      new Response(JSON.stringify({ UserConfirmed: true }), {
        status: 200,
        headers: { "content-type": "application/json" },
      }),
    );

    await signUpWithBootstrap({
      configuration: {
        ...configuration,
        issuer: "https://cognito-idp.us-west-2.amazonaws.com/us-west-2_pool",
      },
      username: "qa-user",
      password: "Strong-Test-Password-42!",
      bootstrapToken: "mac-approved-token",
    });

    expect(fetchMock.mock.calls[0]?.[0]).toBe("https://cognito-idp.us-west-2.amazonaws.com");
    const body = JSON.parse(String(fetchMock.mock.calls[0]?.[1]?.body)) as Record<string, any>;
    expect(body).toMatchObject({
      ClientId: "web-client",
      Username: "qa-user",
      ClientMetadata: { bootstrapToken: "mac-approved-token" },
    });
    expect(body).not.toHaveProperty("UserAttributes");
  });

  it("changes the password directly with Cognito instead of the TerminalDB API", async () => {
    const fetchMock = vi.spyOn(globalThis, "fetch").mockResolvedValue(
      new Response("{}", { status: 200 }),
    );

    await changeAccountPassword({
      configuration: {
        ...configuration,
        issuer: "https://cognito-idp.us-west-2.amazonaws.com/us-west-2_pool",
      },
      accessToken: "access-token",
      currentPassword: "Old-Strong-Password-42!",
      newPassword: "New-Strong-Password-42!",
    });

    expect(fetchMock.mock.calls[0]?.[0]).toBe("https://cognito-idp.us-west-2.amazonaws.com");
    expect(fetchMock.mock.calls[0]?.[1]?.headers).toMatchObject({
      "x-amz-target": "AWSCognitoIdentityProviderService.ChangePassword",
    });
    expect(JSON.parse(String(fetchMock.mock.calls[0]?.[1]?.body))).toEqual({
      AccessToken: "access-token",
      PreviousPassword: "Old-Strong-Password-42!",
      ProposedPassword: "New-Strong-Password-42!",
    });
  });

  it("recognizes only a freshly issued access token for sensitive actions", () => {
    const issuedAt = 1_700_000_000;
    const claims = btoa(JSON.stringify({ iat: issuedAt }))
      .replace(/\+/gu, "-")
      .replace(/\//gu, "_")
      .replace(/=+$/gu, "");
    const token = `header.${claims}.signature`;

    expect(accountTokenIssuedAt(token)).toBe(issuedAt);
    expect(hasRecentAccountAuthentication(token, 300, issuedAt + 299)).toBe(true);
    expect(hasRecentAccountAuthentication(token, 300, issuedAt + 301)).toBe(false);
    expect(hasRecentAccountAuthentication("not-a-token", 300, issuedAt)).toBe(false);
  });

  it("never restores an external post-authentication URL", async () => {
    sessionStorage.setItem("terminaldb.account.oauth-state.v1", "expected-state");
    sessionStorage.setItem("terminaldb.account.pkce-verifier.v1", "pkce-verifier");
    sessionStorage.setItem("terminaldb.account.return-to.v1", "https://attacker.example/steal");
    history.replaceState({}, "", "/auth/callback?code=one-time-code&state=expected-state");
    vi.spyOn(globalThis, "fetch").mockResolvedValue(
      new Response(JSON.stringify({ access_token: "access-token", expires_in: 3_600 }), {
        status: 200,
        headers: { "content-type": "application/json" },
      }),
    );

    await completeAccountSignIn(configuration);

    expect(`${location.pathname}${location.search}`).toBe("/");
  });

  it("refreshes an expired access token without exposing the refresh token in the URL", async () => {
    localStorage.setItem("terminaldb.account.tokens.v1", JSON.stringify({
      accessToken: "expired-access",
      refreshToken: "refresh-secret",
      expiresAt: Date.now() - 1,
    }));
    const fetchMock = vi.spyOn(globalThis, "fetch").mockResolvedValue(
      new Response(JSON.stringify({ access_token: "fresh-access", expires_in: 3_600 }), {
        status: 200,
        headers: { "content-type": "application/json" },
      }),
    );

    await expect(accountAccessToken(configuration)).resolves.toBe("fresh-access");

    expect(fetchMock.mock.calls[0]?.[0]).toBe("https://login.example.invalid/oauth2/token");
    const body = String(fetchMock.mock.calls[0]?.[1]?.body);
    expect(body).toContain("grant_type=refresh_token");
    expect(body).toContain("refresh_token=refresh-secret");
    expect(String(fetchMock.mock.calls[0]?.[0])).not.toContain("refresh-secret");
  });

  it("revokes the refresh token before navigating to Cognito logout", async () => {
    localStorage.setItem("terminaldb.account.tokens.v1", JSON.stringify({
      accessToken: "access-token",
      refreshToken: "refresh-secret",
      expiresAt: Date.now() + 3_600_000,
    }));
    const fetchMock = vi.spyOn(globalThis, "fetch").mockResolvedValue(new Response("", { status: 200 }));
    const navigate = vi.fn();

    await signOutAccount(configuration, navigate);

    expect(fetchMock.mock.calls[0]?.[0]).toBe("https://login.example.invalid/oauth2/revoke");
    expect(String(fetchMock.mock.calls[0]?.[1]?.body)).toContain("token=refresh-secret");
    expect(localStorage.getItem("terminaldb.account.tokens.v1")).toBeNull();
    const logout = navigate.mock.calls[0]?.[0] as URL;
    expect(logout.pathname).toBe("/logout");
    expect(logout.searchParams.get("client_id")).toBe("web-client");
  });

  it("discards cached credentials after the account access policy changes", () => {
    localStorage.setItem("terminaldb.account.tokens.v1", JSON.stringify({
      accessToken: "revoked-access-token",
      refreshToken: "revoked-refresh-token",
      expiresAt: Date.now() + 3_600_000,
    }));

    clearAccountCredentials();

    expect(localStorage.getItem("terminaldb.account.tokens.v1")).toBeNull();
  });

  it("rejects a callback whose state was not created by this browser", async () => {
    sessionStorage.setItem("terminaldb.account.oauth-state.v1", "expected-state");
    sessionStorage.setItem("terminaldb.account.pkce-verifier.v1", "pkce-verifier");
    history.replaceState({}, "", "/auth/callback?code=one-time-code&state=attacker-state");
    const fetchMock = vi.spyOn(globalThis, "fetch");

    await expect(completeAccountSignIn(configuration)).rejects.toThrow(
      "could not be verified",
    );
    expect(fetchMock).not.toHaveBeenCalled();
    expect(localStorage.getItem("terminaldb.account.tokens.v1")).toBeNull();
  });
});
