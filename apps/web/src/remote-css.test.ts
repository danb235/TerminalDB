import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { describe, expect, it } from "vitest";

const styles = readFileSync(resolve(process.cwd(), "src/remote.css"), "utf8");

describe("account form styles", () => {
  it("keeps Safari credential autofill on the TerminalDB dark surface", () => {
    expect(styles).not.toContain("var(--tdb-black)");
    expect(styles).toContain(".account-access input:-webkit-autofill");
    expect(styles).toContain(
      "-webkit-box-shadow: 0 0 0 1000px var(--tdb-terminal) inset !important;",
    );
    expect(styles).toContain("-webkit-text-fill-color: var(--tdb-text) !important;");
  });
});
