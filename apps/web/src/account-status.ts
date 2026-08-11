import { accountAccessToken } from "./account-auth";
import { loadPublicConfiguration } from "./remote-client";

export const ACCOUNT_STATUS_MESSAGE = "terminaldb-account-status-v1";
export const ACCOUNT_STATUS_REQUEST = "terminaldb-account-status-request-v1";

const MARKETING_ORIGINS = new Set([
  "https://terminaldb.app",
  "https://www.terminaldb.app",
]);

export interface MarketingAccountStatus {
  readonly type: typeof ACCOUNT_STATUS_MESSAGE;
  readonly signedIn: boolean;
  readonly username?: string;
}

export function isApprovedMarketingOrigin(
  origin: string,
  development = import.meta.env.DEV,
): boolean {
  if (MARKETING_ORIGINS.has(origin)) return true;
  if (!development) return false;
  try {
    const parsed = new URL(origin);
    return parsed.protocol === "http:" &&
      ["127.0.0.1", "localhost"].includes(parsed.hostname);
  } catch {
    return false;
  }
}

export function accountUsername(accessToken: string): string | undefined {
  const encoded = accessToken.split(".")[1];
  if (!encoded) return undefined;
  try {
    const normalized = encoded.replace(/-/gu, "+").replace(/_/gu, "/");
    const padding = "=".repeat((4 - (normalized.length % 4)) % 4);
    const claims = JSON.parse(atob(`${normalized}${padding}`)) as {
      readonly username?: unknown;
      readonly ["cognito:username"]?: unknown;
    };
    const username = claims.username ?? claims["cognito:username"];
    return typeof username === "string" && username.trim() ? username : undefined;
  } catch {
    return undefined;
  }
}

async function currentAccountStatus(): Promise<MarketingAccountStatus> {
  try {
    const configuration = await loadPublicConfiguration();
    if (!configuration.accountAuth) {
      return { type: ACCOUNT_STATUS_MESSAGE, signedIn: false };
    }
    const token = await accountAccessToken(configuration.accountAuth);
    if (!token) return { type: ACCOUNT_STATUS_MESSAGE, signedIn: false };
    const username = accountUsername(token);
    return {
      type: ACCOUNT_STATUS_MESSAGE,
      signedIn: true,
      ...(username ? { username } : {}),
    };
  } catch {
    return { type: ACCOUNT_STATUS_MESSAGE, signedIn: false };
  }
}

export function startAccountStatusBridge(): void {
  if (window.parent === window) return;
  let parentOrigin: string | undefined;
  let reporting = false;

  const report = async () => {
    if (!parentOrigin || reporting) return;
    reporting = true;
    try {
      window.parent.postMessage(await currentAccountStatus(), parentOrigin);
    } finally {
      reporting = false;
    }
  };

  window.addEventListener("message", (event) => {
    if (
      event.source !== window.parent ||
      !isApprovedMarketingOrigin(event.origin) ||
      !event.data ||
      event.data.type !== ACCOUNT_STATUS_REQUEST
    ) {
      return;
    }
    parentOrigin = event.origin;
    void report();
  });
  window.addEventListener("storage", () => void report());

  try {
    const referrerOrigin = document.referrer
      ? new URL(document.referrer).origin
      : undefined;
    if (referrerOrigin && isApprovedMarketingOrigin(referrerOrigin)) {
      parentOrigin = referrerOrigin;
      void report();
    }
  } catch {
    // The parent handshake still establishes a verified origin.
  }
}

startAccountStatusBridge();
