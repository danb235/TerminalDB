import { describe, expect, it } from "vitest";

import { dashboardSessionPresentation } from "./App";

describe("remote session dashboard presentation", () => {
  it("keeps an honest loading state before the first inventory arrives", () => {
    expect(dashboardSessionPresentation("loading", 0, "connecting")).toBe("loading");
    expect(dashboardSessionPresentation("loading", 0, "reconnecting")).toBe("loading");
    expect(dashboardSessionPresentation("loading", 0, "resyncing")).toBe("loading");
    expect(dashboardSessionPresentation("ready", 0, "reconnecting")).toBe("loading");
  });

  it("shows an empty state only after an empty inventory is confirmed", () => {
    expect(dashboardSessionPresentation("ready", 0, "live")).toBe("empty");
  });

  it("explains that an unavailable Mac can come back without signing in again", () => {
    expect(dashboardSessionPresentation("loading", 0, "mac-offline")).toBe("offline");
    expect(dashboardSessionPresentation("ready", 0, "phone-offline")).toBe("offline");
    expect(dashboardSessionPresentation("ready", 0, "remote-ended")).toBe("offline");
  });

  it("always presents real sessions immediately", () => {
    expect(dashboardSessionPresentation("loading", 2, "resyncing")).toBe("sessions");
  });
});
