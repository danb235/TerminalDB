import { describe, expect, it } from "vitest";

import { adaptSnapshotToLocalViewport } from "./terminal-viewport";

describe("independent web terminal viewport", () => {
  it("keeps the cursor at the same distance from the bottom on a taller web viewport", () => {
    const snapshot = "history\r\n\x1b[0m\x1b[13;9H\x1b[?25h";
    expect(adaptSnapshotToLocalViewport(snapshot, 17, 40, 160)).toBe(
      "history\r\n\x1b[0m\x1b[36;9H\x1b[?25h",
    );
  });

  it("clamps cursor coordinates when the web viewport is smaller", () => {
    const snapshot = "history\r\n\x1b[0m\x1b[2;90H\x1b[?25l";
    expect(adaptSnapshotToLocalViewport(snapshot, 24, 10, 46)).toBe(
      "history\r\n\x1b[0m\x1b[1;46H\x1b[?25l",
    );
  });

  it("does not rewrite incremental PTY output", () => {
    const output = "plain output\r\n";
    expect(adaptSnapshotToLocalViewport(output, 24, 40, 160)).toBe(output);
  });
});
