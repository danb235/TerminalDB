import { describe, expect, it } from "vitest";

import {
  optimisticRenderForInput,
  reconcileOptimisticEcho,
} from "./optimistic-input";

describe("optimistic terminal input", () => {
  it("renders normal shell text, erase, and Return immediately", () => {
    expect(optimisticRenderForInput("ls -a\x7fll\r", "echo")).toEqual({
      rendered: "ls -a\b \bll\r\n",
      expectedEcho: "ls -a\b \bll\r\n",
      editableCells: 0,
    });
  });

  it("renders a Claude-style application draft without assuming PTY echo", () => {
    expect(optimisticRenderForInput("explain this", "application")).toEqual({
      rendered: "explain this",
      expectedEcho: "",
      editableCells: 12,
    });
  });

  it("never lets speculative Backspace cross the prompt boundary", () => {
    expect(optimisticRenderForInput("\x7f\x7f", "application", 0)).toEqual({
      rendered: "",
      expectedEcho: "",
      editableCells: 0,
    });
    expect(optimisticRenderForInput("pwd\x7f\x7f\x7f\x7f", "application", 0))
      .toEqual({
        rendered: "pwd\b \b\b \b\b \b",
        expectedEcho: "",
        editableCells: 0,
      });
  });

  it("never paints secure input or partial control sequences", () => {
    expect(optimisticRenderForInput("hunter2", "secure")).toBeUndefined();
    expect(optimisticRenderForInput("\u001b[A", "echo")).toBeUndefined();
    expect(optimisticRenderForInput("\t", "application")).toBeUndefined();
  });

  it("suppresses an echoed prefix across fragmented PTY updates", () => {
    expect(reconcileOptimisticEcho("hello", "he")).toEqual({
      expectedEcho: "llo",
      output: "",
      mismatch: false,
    });
    expect(reconcileOptimisticEcho("llo", "llo\r\nresult\r\n")).toEqual({
      expectedEcho: "",
      output: "\r\nresult\r\n",
      mismatch: false,
    });
  });

  it("requires authoritative rebuild when PTY redraw differs", () => {
    expect(reconcileOptimisticEcho("hello", "\u001b[2Khello")).toEqual({
      expectedEcho: "hello",
      output: "\u001b[2Khello",
      mismatch: true,
    });
  });
});
