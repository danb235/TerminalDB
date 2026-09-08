import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { describe, expect, it } from "vitest";

import { IDLE_HEALTH_INTERVAL_MS } from "./remote-client";

// The Mac agent prunes a controller it has not heard from, which stops the
// relay traffic that would otherwise be rejected with 403 forever. An idle
// browser is silent between health pings, so the agent's patience has to
// exceed this client's ping interval by a comfortable margin or a browser
// that is still watching would be dropped. Both numbers live in different
// languages, so read the Swift source rather than trusting a copy of it.
const agentSource = readFileSync(
  resolve(process.cwd(), "../macos/remote-agent/TerminalDBRemoteAgent.swift"),
  "utf8",
);

function agentControllerLivenessTimeoutMs(): number {
  const match =
    /controllerLivenessTimeout:\s*TimeInterval\s*=\s*(\d+(?:\.\d+)?)/u.exec(agentSource);
  if (!match) throw new Error("controllerLivenessTimeout is missing from the Mac agent");
  return Number(match[1]) * 1_000;
}

describe("controller liveness contract with the Mac agent", () => {
  it("gives an idle browser at least two health pings before the agent prunes it", () => {
    expect(agentControllerLivenessTimeoutMs()).toBeGreaterThanOrEqual(
      IDLE_HEALTH_INTERVAL_MS * 2,
    );
  });

  it("still prunes a vanished controller within fifteen minutes", () => {
    expect(agentControllerLivenessTimeoutMs()).toBeLessThanOrEqual(15 * 60 * 1_000);
  });
});
