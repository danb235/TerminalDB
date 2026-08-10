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
const RETURN_TO_KEY = "terminaldb.account.return-to.v1";
const BOOTSTRAP_KEY = "terminaldb.account.bootstrap.v1";

export interface AccountAuthorizationOptions {
  readonly returnTo?: string;
  readonly loginHint?: string;
}

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
  options: AccountAuthorizationOptions = {},
): Promise<void> {
  await beginAccountAuthorization(configuration, "/oauth2/authorize", navigate, options);
}

async function beginAccountAuthorization(
  configuration: AccountAuthConfiguration,
  path: "/oauth2/authorize",
  navigate: (url: URL) => void,
  options: AccountAuthorizationOptions,
): Promise<void> {
  const state = randomValue();
  const verifier = randomValue(48);
  sessionStorage.setItem(STATE_KEY, state);
  sessionStorage.setItem(VERIFIER_KEY, verifier);
  if (options.returnTo) sessionStorage.setItem(RETURN_TO_KEY, options.returnTo);
  else sessionStorage.removeItem(RETURN_TO_KEY);
  const url = new URL(`${trimSlash(configuration.domain)}${path}`);
  url.searchParams.set("client_id", configuration.clientId);
  url.searchParams.set("response_type", "code");
  url.searchParams.set("scope", "openid profile");
  url.searchParams.set("redirect_uri", callbackUrl(configuration));
  url.searchParams.set("state", state);
  url.searchParams.set("code_challenge_method", "S256");
  url.searchParams.set("code_challenge", await challenge(verifier));
  if (options.loginHint) url.searchParams.set("login_hint", options.loginHint);
  navigate(url);
}

function cognitoApiEndpoint(configuration: AccountAuthConfiguration): string {
  const issuer = new URL(configuration.issuer);
  if (issuer.protocol !== "https:" || !issuer.hostname.startsWith("cognito-idp.")) {
    throw new Error("Account signup is not configured correctly");
  }
  return issuer.origin;
}

export async function signUpWithBootstrap(input: {
  readonly configuration: AccountAuthConfiguration;
  readonly username: string;
  readonly password: string;
  readonly bootstrapToken: string;
}): Promise<void> {
  const response = await fetch(cognitoApiEndpoint(input.configuration), {
    method: "POST",
    headers: {
      "content-type": "application/x-amz-json-1.1",
      "x-amz-target": "AWSCognitoIdentityProviderService.SignUp",
    },
    body: JSON.stringify({
      ClientId: input.configuration.clientId,
      Username: input.username,
      Password: input.password,
      ClientMetadata: { bootstrapToken: input.bootstrapToken },
    }),
  });
  if (response.ok) return;
  const failure = await response.json().catch(() => ({})) as {
    readonly __type?: string;
    readonly message?: string;
  };
  const kind = failure.__type?.split("#").at(-1);
  if (kind === "UsernameExistsException") {
    throw new Error(
      "That username already exists. Sign in to finish authenticator setup or access the account.",
    );
  }
  if (kind === "InvalidPasswordException") {
    throw new Error("Use at least 12 characters with upper and lowercase letters, a number, and a symbol.");
  }
  if (kind === "UserLambdaValidationException") {
    throw new Error("This Mac approval expired. Start account creation again from TerminalDB.");
  }
  throw new Error(failure.message ?? `Account creation failed (${response.status})`);
}

export function savePendingAccountBootstrap(token: string): void {
  sessionStorage.setItem(BOOTSTRAP_KEY, token);
}

export function pendingAccountBootstrap(): string | undefined {
  return sessionStorage.getItem(BOOTSTRAP_KEY) ?? undefined;
}

export function clearPendingAccountBootstrap(): void {
  sessionStorage.removeItem(BOOTSTRAP_KEY);
}

export function clearAccountCredentials(): void {
  localStorage.removeItem(TOKEN_KEY);
}

function safeReturnPath(value: string | null): string {
  if (!value) return "/";
  try {
    const target = new URL(value, location.origin);
    if (target.origin !== location.origin) return "/";
    return `${target.pathname}${target.search}`;
  } catch {
    return "/";
  }
}

export async function completeAccountSignIn(
  configuration: AccountAuthConfiguration,
): Promise<boolean> {
  if (location.pathname !== configuration.callbackPath) return false;
  const query = new URLSearchParams(location.search);
  const returnedState = query.get("state");
  const expectedState = sessionStorage.getItem(STATE_KEY);
  const verifier = sessionStorage.getItem(VERIFIER_KEY);
  const returnTo = sessionStorage.getItem(RETURN_TO_KEY);
  const code = query.get("code");
  sessionStorage.removeItem(STATE_KEY);
  sessionStorage.removeItem(VERIFIER_KEY);
  sessionStorage.removeItem(RETURN_TO_KEY);
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
  history.replaceState({}, "", safeReturnPath(returnTo));
  return true;
}

export async function accountAccessToken(
  configuration: AccountAuthConfiguration,
): Promise<string | undefined> {
  const current = loadTokens();
  if (!current) return undefined;
  if (current.expiresAt > Date.now() + 30_000) return current.accessToken;
  if (!current.refreshToken) {
    clearAccountCredentials();
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
    clearAccountCredentials();
    return undefined;
  }
}

export async function signOutAccount(
  configuration: AccountAuthConfiguration,
  navigate: (url: URL) => void = (url) => location.assign(url),
): Promise<void> {
  const tokens = loadTokens();
  clearAccountCredentials();
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
