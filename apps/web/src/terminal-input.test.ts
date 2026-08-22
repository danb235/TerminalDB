import { describe, expect, it } from "vitest";

import {
  commandInputForPTY,
  terminalInputChunks,
} from "./terminal-input";

describe("terminal command input", () => {
  it("submits a single-line draft with Return", () => {
    expect(commandInputForPTY("ls -al")).toBe("ls -al\r");
  });

  it("normalizes multiline drafts without adding a duplicate Return", () => {
    expect(commandInputForPTY("printf one\nprintf two\n")).toBe(
      "printf one\rprintf two\r",
    );
  });

  it("chunks long pasted text without losing or corrupting its tail", () => {
    const input = `BEGIN\n${"paved-road 🙂 ".repeat(2_000)}\nTAIL_SENTINEL`;
    const chunks = terminalInputChunks(input, 512);
    const encoder = new TextEncoder();

    expect(chunks.length).toBeGreaterThan(2);
    expect(chunks.join("")).toBe(input);
    expect(chunks.at(-1)).toContain("TAIL_SENTINEL");
    expect(chunks.every((chunk) => encoder.encode(chunk).byteLength <= 512))
      .toBe(true);
  });

  it("never splits a multi-byte Unicode scalar", () => {
    expect(terminalInputChunks("aa🙂bb", 4)).toEqual(["aa", "🙂", "bb"]);
  });
});
