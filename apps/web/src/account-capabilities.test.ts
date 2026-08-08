import { describe, expect, it } from "vitest";

import { accountBootstrapSupport } from "./App";

describe("Mac account capability negotiation", () => {
  it("waits until the first Mac inventory arrives", () => {
    expect(accountBootstrapSupport({ instances: [] })).toBe("checking");
  });

  it("requires an update when a connected Mac omits account approval", () => {
    expect(accountBootstrapSupport({
      instances: [],
      capabilities: ["sequenced-input-v1", "causal-input-output-v1"],
    })).toBe("upgrade-required");
  });

  it("allows account approval even when the capable Mac has no open windows", () => {
    expect(accountBootstrapSupport({
      instances: [],
      capabilities: ["account-bootstrap-v1"],
    })).toBe("supported");
  });
});
