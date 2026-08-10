import { describe, expect, it } from "vitest";

import { accountBootstrapSupport, accountDeviceActivityLabel } from "./App";

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

describe("account Mac activity labels", () => {
  const now = Date.UTC(2026, 7, 10, 12, 0, 0);

  it("uses calm relative labels without exposing enrollment metadata", () => {
    expect(accountDeviceActivityLabel(0, now)).toBe("Never online");
    expect(accountDeviceActivityLabel(now / 1_000 - 20, now)).toBe("Last seen just now");
    expect(accountDeviceActivityLabel(now / 1_000 - 8 * 60, now)).toBe("Last seen 8m ago");
    expect(accountDeviceActivityLabel(now / 1_000 - 3 * 60 * 60, now)).toBe("Last seen 3h ago");
    expect(accountDeviceActivityLabel(now / 1_000 - 2 * 24 * 60 * 60, now)).toBe("Last seen 2d ago");
  });
});
