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
  readonly refreshMode?: "oauth" | "cognito";
}

interface TokenResponse {
  readonly access_token?: string;
  readonly refresh_token?: string;
  readonly expires_in?: number;
}

interface CognitoAuthenticationResult {
  readonly AccessToken?: string;
  readonly RefreshToken?: string;
  readonly ExpiresIn?: number;
}

interface CognitoChallengeResponse {
  readonly ChallengeName?: string;
  readonly Session?: string;
  readonly SecretCode?: string;
  readonly Status?: string;
  readonly AuthenticationResult?: CognitoAuthenticationResult;
}

interface CognitoFailure {
  readonly __type?: string;
  readonly message?: string;
}

export interface AccountTotpEnrollment {
  readonly username: string;
  readonly secret: string;
  readonly session: string;
}

const TOKEN_KEY = "terminaldb.account.tokens.v1";
const STATE_KEY = "terminaldb.account.oauth-state.v1";
const VERIFIER_KEY = "terminaldb.account.pkce-verifier.v1";
const RETURN_TO_KEY = "terminaldb.account.return-to.v1";
const BOOTSTRAP_KEY = "terminaldb.account.bootstrap.v1";

export interface AccountAuthorizationOptions {
  readonly returnTo?: string;
  readonly loginHint?: string;
  readonly forceReauthentication?: boolean;
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
    refreshMode: previous?.refreshMode ?? "oauth",
  };
  localStorage.setItem(TOKEN_KEY, JSON.stringify(tokens));
  return tokens;
}

function saveCognitoTokens(
  response: CognitoAuthenticationResult,
  previous?: StoredTokens,
): StoredTokens {
  if (!response.AccessToken) throw new Error("Cognito did not return an access token");
  const refreshToken = response.RefreshToken ?? previous?.refreshToken;
  const tokens: StoredTokens = {
    accessToken: response.AccessToken,
    ...(refreshToken ? { refreshToken } : {}),
    expiresAt: Date.now() + Math.max(60, response.ExpiresIn ?? 3_600) * 1_000,
    refreshMode: "cognito",
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

export async function beginAccountSignUp(
  configuration: AccountAuthConfiguration,
  navigate: (url: URL) => void = (url) => location.assign(url),
  options: AccountAuthorizationOptions = {},
): Promise<void> {
  await beginAccountAuthorization(configuration, "/signup", navigate, options);
}

async function beginAccountAuthorization(
  configuration: AccountAuthConfiguration,
  path: "/oauth2/authorize" | "/signup",
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
  url.searchParams.set("scope", "openid profile aws.cognito.signin.user.admin");
  url.searchParams.set("redirect_uri", callbackUrl(configuration));
  url.searchParams.set("state", state);
  url.searchParams.set("code_challenge_method", "S256");
  url.searchParams.set("code_challenge", await challenge(verifier));
  if (options.loginHint) url.searchParams.set("login_hint", options.loginHint);
  if (options.forceReauthentication) url.searchParams.set("prompt", "login");
  navigate(url);
}

function cognitoApiEndpoint(configuration: AccountAuthConfiguration): string {
  const issuer = new URL(configuration.issuer);
  if (issuer.protocol !== "https:" || !issuer.hostname.startsWith("cognito-idp.")) {
    throw new Error("Account signup is not configured correctly");
  }
  return issuer.origin;
}

function cognitoFailureName(failure: CognitoFailure): string | undefined {
  return failure.__type?.split("#").at(-1);
}

function friendlyCognitoError(failure: CognitoFailure, status: number): Error {
  switch (cognitoFailureName(failure)) {
    case "UsernameExistsException":
      return new Error("That username is already registered. Sign in instead.");
    case "InvalidPasswordException":
      return new Error(
        "Use at least 12 characters with upper and lowercase letters, a number, and a symbol.",
      );
    case "CodeMismatchException":
    case "EnableSoftwareTokenMFAException":
      return new Error("That code was not accepted. Wait for a new code and try again.");
    case "NotAuthorizedException":
      return new Error("That username is already registered, or the password was not accepted.");
    case "LimitExceededException":
    case "TooManyRequestsException":
      return new Error("Too many attempts. Wait a moment and try again.");
    default:
      return new Error(failure.message ?? `Account setup failed (${status})`);
  }
}

async function cognitoRequest(
  configuration: AccountAuthConfiguration,
  operation: string,
  body: Record<string, unknown>,
): Promise<CognitoChallengeResponse> {
  const response = await fetch(cognitoApiEndpoint(configuration), {
    method: "POST",
    headers: {
      "content-type": "application/x-amz-json-1.1",
      "x-amz-target": `AWSCognitoIdentityProviderService.${operation}`,
    },
    body: JSON.stringify(body),
  });
  const payload = await response.json().catch(() => ({})) as CognitoChallengeResponse & CognitoFailure;
  if (!response.ok) throw friendlyCognitoError(payload, response.status);
  return payload;
}

export async function beginAccountTotpEnrollment(input: {
  readonly configuration: AccountAuthConfiguration;
  readonly username: string;
  readonly password: string;
  readonly bootstrapToken: string;
}): Promise<AccountTotpEnrollment> {
  const username = input.username.trim();
  if (!username) throw new Error("Choose a username.");
  if (!input.password) throw new Error("Choose a password.");

  try {
    await cognitoRequest(input.configuration, "SignUp", {
      ClientId: input.configuration.clientId,
      Username: username,
      Password: input.password,
      ClientMetadata: { bootstrapToken: input.bootstrapToken },
    });
  } catch (error) {
    if (!(error instanceof Error) || error.message !== "That username is already registered. Sign in instead.") {
      throw error;
    }
    // A browser may have closed after Cognito created the account but before
    // TOTP enrollment finished. The same password can safely resume that
    // incomplete ceremony; a completed account is directed to normal sign-in.
  }

  const authentication = await cognitoRequest(input.configuration, "InitiateAuth", {
    AuthFlow: "USER_AUTH",
    ClientId: input.configuration.clientId,
    AuthParameters: {
      USERNAME: username,
      PASSWORD: input.password,
      PREFERRED_CHALLENGE: "PASSWORD",
    },
  });
  if (authentication.ChallengeName !== "MFA_SETUP" || !authentication.Session) {
    throw new Error("That account is already configured. Sign in instead.");
  }
  const association = await cognitoRequest(input.configuration, "AssociateSoftwareToken", {
    Session: authentication.Session,
  });
  if (!association.SecretCode || !association.Session) {
    throw new Error("Cognito could not start authenticator setup. Try again.");
  }
  return {
    username,
    secret: association.SecretCode,
    session: association.Session,
  };
}

export async function completeAccountTotpEnrollment(input: {
  readonly configuration: AccountAuthConfiguration;
  readonly enrollment: AccountTotpEnrollment;
  readonly code: string;
}): Promise<string> {
  const code = input.code.replace(/\s/gu, "");
  if (!/^\d{6}$/u.test(code)) throw new Error("Enter the six-digit code from your authenticator app.");
  const verification = await cognitoRequest(input.configuration, "VerifySoftwareToken", {
    Session: input.enrollment.session,
    UserCode: code,
    FriendlyDeviceName: "TerminalDB",
  });
  if (verification.Status !== "SUCCESS" || !verification.Session) {
    throw new Error("That code was not accepted. Wait for a new code and try again.");
  }
  const completion = await cognitoRequest(input.configuration, "RespondToAuthChallenge", {
    ClientId: input.configuration.clientId,
    ChallengeName: "MFA_SETUP",
    ChallengeResponses: { USERNAME: input.enrollment.username },
    Session: verification.Session,
  });
  const tokens = saveCognitoTokens(completion.AuthenticationResult ?? {});
  return tokens.accessToken;
}

export async function changeAccountPassword(input: {
  readonly configuration: AccountAuthConfiguration;
  readonly accessToken: string;
  readonly currentPassword: string;
  readonly newPassword: string;
}): Promise<void> {
  const response = await fetch(cognitoApiEndpoint(input.configuration), {
    method: "POST",
    headers: {
      "content-type": "application/x-amz-json-1.1",
      "x-amz-target": "AWSCognitoIdentityProviderService.ChangePassword",
    },
    body: JSON.stringify({
      AccessToken: input.accessToken,
      PreviousPassword: input.currentPassword,
      ProposedPassword: input.newPassword,
    }),
  });
  if (response.ok) return;
  const failure = await response.json().catch(() => ({})) as {
    readonly __type?: string;
    readonly message?: string;
  };
  const kind = failure.__type?.split("#").at(-1);
  if (kind === "NotAuthorizedException") {
    throw new Error("The current password was not accepted. Sign in again and retry.");
  }
  if (kind === "InvalidPasswordException") {
    throw new Error("Use at least 12 characters with upper and lowercase letters, a number, and a symbol.");
  }
  throw new Error(failure.message ?? `Password change failed (${response.status})`);
}

export function accountTokenIssuedAt(accessToken: string): number | undefined {
  const encoded = accessToken.split(".")[1];
  if (!encoded) return undefined;
  try {
    const normalized = encoded.replace(/-/gu, "+").replace(/_/gu, "/");
    const padding = "=".repeat((4 - (normalized.length % 4)) % 4);
    const claims = JSON.parse(atob(`${normalized}${padding}`)) as { readonly iat?: unknown };
    return typeof claims.iat === "number" && Number.isSafeInteger(claims.iat)
      ? claims.iat
      : undefined;
  } catch {
    return undefined;
  }
}

export function hasRecentAccountAuthentication(
  accessToken: string,
  maximumAgeSeconds = 5 * 60,
  nowSeconds = Math.floor(Date.now() / 1_000),
): boolean {
  const issuedAt = accountTokenIssuedAt(accessToken);
  return issuedAt !== undefined && issuedAt <= nowSeconds + 60 &&
    issuedAt >= nowSeconds - maximumAgeSeconds;
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
    if (current.refreshMode === "cognito") {
      const response = await cognitoRequest(configuration, "InitiateAuth", {
        AuthFlow: "REFRESH_TOKEN_AUTH",
        ClientId: configuration.clientId,
        AuthParameters: { REFRESH_TOKEN: current.refreshToken },
      });
      return saveCognitoTokens(response.AuthenticationResult ?? {}, current).accessToken;
    }
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
