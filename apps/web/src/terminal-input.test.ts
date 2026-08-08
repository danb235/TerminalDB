import { describe, expect, it } from "vitest";

import { commandInputForPTY } from "./terminal-input";

describe("terminal command input", () => {
  it("submits a single-line draft with Return", () => {
    expect(commandInputForPTY("ls -al")).toBe("ls -al\r");
  });

  it("normalizes multiline drafts without adding a duplicate Return", () => {
    expect(commandInputForPTY("printf one\nprintf two\n")).toBe(
      "printf one\rprintf two\r",
    );
  });
});
