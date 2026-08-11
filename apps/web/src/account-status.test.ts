import { describe, expect, it } from "vitest";

import { accountUsername, isApprovedMarketingOrigin } from "./account-status";

function token(claims: Record<string, unknown>): string {
  const encoded = btoa(JSON.stringify(claims))
    .replace(/\+/gu, "-")
    .replace(/\//gu, "_")
    .replace(/=+$/gu, "");
  return `header.${encoded}.signature`;
}

describe("marketing account status bridge", () => {
  it("accepts only TerminalDB marketing origins in production", () => {
    expect(isApprovedMarketingOrigin("https://terminaldb.app", false)).toBe(true);
    expect(isApprovedMarketingOrigin("https://www.terminaldb.app", false)).toBe(true);
    expect(isApprovedMarketingOrigin("https://app.terminaldb.app", false)).toBe(false);
    expect(isApprovedMarketingOrigin("https://terminaldb.app.evil.example", false)).toBe(false);
    expect(isApprovedMarketingOrigin("http://terminaldb.app", false)).toBe(false);
  });

  it("allows loopback origins only for local development", () => {
    expect(isApprovedMarketingOrigin("http://127.0.0.1:4173", true)).toBe(true);
    expect(isApprovedMarketingOrigin("http://localhost:8080", true)).toBe(true);
    expect(isApprovedMarketingOrigin("http://127.0.0.1:4173", false)).toBe(false);
  });

  it("reads only the display username from a Cognito access token", () => {
    expect(accountUsername(token({ username: "demo-user", sub: "secret-sub" })))
      .toBe("demo-user");
    expect(accountUsername(token({ "cognito:username": "legacy-user" })))
      .toBe("legacy-user");
    expect(accountUsername("not-a-token")).toBeUndefined();
  });
});
