import { describe, expect, it } from "vitest";

import { accountTenantMatches } from "../lambdas/common.js";

describe("account tenant boundary", () => {
  it("accepts only the same non-empty immutable subject at all three boundaries", () => {
    expect(accountTenantMatches({
      controllerOwnerSub: "tenant-a",
      sessionOwnerSub: "tenant-a",
      assertedOwnerSub: "tenant-a",
    })).toBe(true);
  });

  it.each([
    ["tenant-a", "tenant-b", "tenant-a"],
    ["tenant-a", "tenant-a", "tenant-b"],
    [undefined, "tenant-a", "tenant-a"],
    ["tenant-a", undefined, "tenant-a"],
    ["", "", ""],
  ])(
    "rejects controller=%s session=%s assertion=%s",
    (controllerOwnerSub, sessionOwnerSub, assertedOwnerSub) => {
      expect(accountTenantMatches({
        controllerOwnerSub,
        sessionOwnerSub,
        assertedOwnerSub,
      })).toBe(false);
    },
  );
});
