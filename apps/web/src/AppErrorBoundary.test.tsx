/** @vitest-environment jsdom */

import React, { act } from "react";
import { createRoot } from "react-dom/client";
import { afterEach, describe, expect, it, vi } from "vitest";

import { AppErrorBoundary } from "./AppErrorBoundary";

function BrokenApp(): React.ReactNode {
  throw new Error("render failed");
}

afterEach(() => {
  document.body.innerHTML = "";
  vi.restoreAllMocks();
});

describe("AppErrorBoundary", () => {
  it("replaces a render crash with a visible recovery action", async () => {
    vi.spyOn(console, "error").mockImplementation(() => undefined);
    const container = document.createElement("div");
    document.body.append(container);
    const root = createRoot(container);

    await act(async () => {
      root.render(
        <AppErrorBoundary>
          <BrokenApp />
        </AppErrorBoundary>,
      );
    });

    expect(container.textContent).toContain("TerminalDB needs a fresh start");
    expect(container.querySelector("button")?.textContent).toBe("Reload TerminalDB");
    root.unmount();
  });
});
