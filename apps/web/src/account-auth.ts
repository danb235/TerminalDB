import { base64UrlEncode, utf8 } from "@terminaldb/protocol";

export interface AccountAuthConfiguration {
  readonly clientId: string;
  readonly domain: string;
  readonly issuer: string;
  readonly callbackPath: string;
}

interface StoredTokens {
  readonly accessToken: string;
  readonly refreshToken?: string;
  readonly expiresAt: number;
}

interface TokenResponse {
  readonly access_token?: string;
  readonly refresh_token?: string;
  readonly expires_in?: number;
}

const TOKEN_KEY = "terminaldb.account.tokens.v1";
const STATE_KEY = "terminaldb.account.oauth-state.v1";
const VERIFIER_KEY = "terminaldb.account.pkce-verifier.v1";

function trimSlash(value: string): string {
  return value.replace(/\/+$/u, "");
}

function callbackUrl(configuration: AccountAuthConfiguration): string {
  return `${location.origin}${configuration.callbackPath}`;
}

function randomValue(bytes = 32): string {
  const value = new Uint8Array(bytes);
  crypto.getRandomValues(value);
  return base64UrlEncode(value);
}

async function challenge(verifier: string): Promise<string> {
  const bytes = utf8(verifier);
  const input = new Uint8Array(bytes.byteLength);
  input.set(bytes);
  const digest = await crypto.subtle.digest("SHA-256", input.buffer);
  return base64UrlEncode(new Uint8Array(digest));
}

function loadTokens(): StoredTokens | undefined {
  const stored = localStorage.getItem(TOKEN_KEY);
  if (!stored) return undefined;
  try {
    const parsed = JSON.parse(stored) as Partial<StoredTokens>;
    if (typeof parsed.accessToken !== "string" || typeof parsed.expiresAt !== "number") {
      return undefined;
    }
    return parsed as StoredTokens;
  } catch {
    return undefined;
  }
}

function saveTokens(response: TokenResponse, previous?: StoredTokens): StoredTokens {
  if (!response.access_token) throw new Error("Cognito did not return an access token");
  const refreshToken = response.refresh_token ?? previous?.refreshToken;
  const tokens: StoredTokens = {
    accessToken: response.access_token,
    ...(refreshToken ? { refreshToken } : {}),
    expiresAt: Date.now() + Math.max(60, response.expires_in ?? 3_600) * 1_000,
  };
  localStorage.setItem(TOKEN_KEY, JSON.stringify(tokens));
  return tokens;
}

async function tokenRequest(
  configuration: AccountAuthConfiguration,
  body: URLSearchParams,
): Promise<TokenResponse> {
  const response = await fetch(`${trimSlash(configuration.domain)}/oauth2/token`, {
    method: "POST",
    headers: { "content-type": "application/x-www-form-urlencoded" },
    body,
  });
  if (!response.ok) throw new Error(`Account sign-in failed (${response.status})`);
  return (await response.json()) as TokenResponse;
}

export async function beginAccountSignIn(
  configuration: AccountAuthConfiguration,
  navigate: (url: URL) => void = (url) => location.assign(url),
): Promise<void> {
  const state = randomValue();
  const verifier = randomValue(48);
  sessionStorage.setItem(STATE_KEY, state);
  sessionStorage.setItem(VERIFIER_KEY, verifier);
  const url = new URL(`${trimSlash(configuration.domain)}/oauth2/authorize`);
  url.searchParams.set("client_id", configuration.clientId);
  url.searchParams.set("response_type", "code");
  url.searchParams.set("scope", "openid email profile");
  url.searchParams.set("redirect_uri", callbackUrl(configuration));
  url.searchParams.set("state", state);
  url.searchParams.set("code_challenge_method", "S256");
  url.searchParams.set("code_challenge", await challenge(verifier));
  navigate(url);
}

export async function completeAccountSignIn(
  configuration: AccountAuthConfiguration,
): Promise<boolean> {
  if (location.pathname !== configuration.callbackPath) return false;
  const query = new URLSearchParams(location.search);
  const returnedState = query.get("state");
  const expectedState = sessionStorage.getItem(STATE_KEY);
  const verifier = sessionStorage.getItem(VERIFIER_KEY);
  const code = query.get("code");
  sessionStorage.removeItem(STATE_KEY);
  sessionStorage.removeItem(VERIFIER_KEY);
  if (!code || !verifier || !expectedState || returnedState !== expectedState) {
    throw new Error("Account sign-in response could not be verified");
  }
  const response = await tokenRequest(
    configuration,
    new URLSearchParams({
      grant_type: "authorization_code",
      client_id: configuration.clientId,
      code,
      code_verifier: verifier,
      redirect_uri: callbackUrl(configuration),
    }),
  );
  saveTokens(response);
  history.replaceState({}, "", "/");
  return true;
}

export async function accountAccessToken(
  configuration: AccountAuthConfiguration,
): Promise<string | undefined> {
  const current = loadTokens();
  if (!current) return undefined;
  if (current.expiresAt > Date.now() + 30_000) return current.accessToken;
  if (!current.refreshToken) {
    localStorage.removeItem(TOKEN_KEY);
    return undefined;
  }
  try {
    const response = await tokenRequest(
      configuration,
      new URLSearchParams({
        grant_type: "refresh_token",
        client_id: configuration.clientId,
        refresh_token: current.refreshToken,
      }),
    );
    return saveTokens(response, current).accessToken;
  } catch {
    localStorage.removeItem(TOKEN_KEY);
    return undefined;
  }
}

export async function signOutAccount(
  configuration: AccountAuthConfiguration,
  navigate: (url: URL) => void = (url) => location.assign(url),
): Promise<void> {
  const tokens = loadTokens();
  localStorage.removeItem(TOKEN_KEY);
  if (tokens?.refreshToken) {
    try {
      await fetch(`${trimSlash(configuration.domain)}/oauth2/revoke`, {
        method: "POST",
        headers: { "content-type": "application/x-www-form-urlencoded" },
        body: new URLSearchParams({
          client_id: configuration.clientId,
          token: tokens.refreshToken,
        }),
      });
    } catch {
      // Local credentials are already gone. Cognito logout below still clears
      // the managed-login cookie if revocation was interrupted.
    }
  }
  const url = new URL(`${trimSlash(configuration.domain)}/logout`);
  url.searchParams.set("client_id", configuration.clientId);
  url.searchParams.set("logout_uri", location.origin);
  navigate(url);
}
