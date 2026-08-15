import { describe, expect, it } from "vitest";

import {
  dashboardDeviceRows,
  dashboardSessionPresentation,
  shouldOpenInitialTerminal,
} from "./App";
import { mockInventory } from "./mock-data";

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

  it("lets account users choose a session while preserving direct one-time links", () => {
    expect(shouldOpenInitialTerminal("account", "dashboard")).toBe(false);
    expect(shouldOpenInitialTerminal("pairing", "dashboard")).toBe(true);
    expect(shouldOpenInitialTerminal("pairing", "accounts")).toBe(false);
  });

  it("combines account devices with the current Mac's windows and tabs", () => {
    const rows = dashboardDeviceRows(mockInventory, "sessions", [
      {
        deviceId: "offline-mac",
        deviceName: "Office iMac",
        registeredAt: 1,
        lastSeenAt: 2,
        state: "offline",
      },
      {
        deviceId: "active-mac",
        deviceName: "Studio Mac",
        registeredAt: 1,
        lastSeenAt: 2,
        state: "online",
        sessionId: "active-session",
        sessionCreatedAt: 2,
      },
    ], "active-session");

    expect(rows).toHaveLength(2);
    expect(rows.find((row) => row.name === "Office iMac")).toMatchObject({
      current: false,
      state: "offline",
      instances: [],
    });
    expect(rows.find((row) => row.name === "Studio Mac")).toMatchObject({
      current: true,
      state: "online",
      instances: mockInventory.instances,
    });
  });

  it("groups one-time sessions by Mac on the same home", () => {
    const rows = dashboardDeviceRows(mockInventory, "sessions", []);
    expect(rows).toHaveLength(1);
    expect(rows[0]).toMatchObject({
      name: "Developer’s Mac",
      current: true,
      instances: mockInventory.instances,
    });
  });
});
