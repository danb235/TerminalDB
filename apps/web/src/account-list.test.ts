import type { ClaudeAccount } from "@terminaldb/protocol";
import { describe, expect, it } from "vitest";

import {
  CLAUDE_USAGE_LABELS,
  stableClaudeAccounts,
  stableClaudeUsage,
} from "./account-list";

function account(
  id: string,
  label: string,
  usage: ClaudeAccount["usage"] = [],
): ClaudeAccount {
  return { id, label, signedIn: true, usage };
}

describe("Claude account picker stability", () => {
  it("keeps the same account order when refreshed inventory arrives reordered", () => {
    const personal = account("personal", "Personal");
    const team = account("team", "SQAD Teams");
    const work = account("work", "Stelao");

    expect(stableClaudeAccounts([work, personal, team]).map(({ id }) => id))
      .toEqual(["personal", "team", "work"]);
    expect(stableClaudeAccounts([team, work, personal]).map(({ id }) => id))
      .toEqual(["personal", "team", "work"]);
  });

  it("reserves every allowance position during a partial usage refresh", () => {
    const usage = stableClaudeUsage(account("work", "Stelao", [
      { label: "Fable", utilization: 48, resetsAt: "Tuesday" },
      { label: "5h", utilization: 14, resetsAt: "Tonight" },
    ]));

    expect(usage.map((window) => window?.label)).toEqual(["5h", undefined, "Fable"]);
    expect(CLAUDE_USAGE_LABELS).toEqual(["5h", "7d", "Fable"]);
  });
});
