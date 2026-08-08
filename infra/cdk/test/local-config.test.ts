import { mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, it } from "vitest";

import { readLocalConfig } from "../lib/local-config.js";

const directories: string[] = [];

afterEach(async () => {
  const { rm } = await import("node:fs/promises");
  await Promise.all(directories.splice(0).map((directory) => rm(directory, { recursive: true })));
});

function fixture(contents?: string): string {
  const directory = mkdtempSync(join(tmpdir(), "terminaldb-cdk-config-"));
  directories.push(directory);
  if (contents !== undefined) {
    writeFileSync(join(directory, "terminaldb-remote.local.json"), contents, { mode: 0o600 });
  }
  return directory;
}

describe("local CDK configuration", () => {
  it("keeps an omitted local file optional", () => {
    expect(readLocalConfig(fixture())).toEqual({});
  });

  it("loads the locally persisted notification address", () => {
    expect(readLocalConfig(fixture('{"budgetEmail":"owner@example.com"}'))).toEqual({
      budgetEmail: "owner@example.com",
    });
  });

  it("rejects malformed or invalid configuration", () => {
    expect(() => readLocalConfig(fixture("[]"))).toThrow(/must be a JSON object/u);
    expect(() => readLocalConfig(fixture('{"budgetEmail":"not-an-email"}'))).toThrow(
      /must be a valid email address/u,
    );
  });
});
