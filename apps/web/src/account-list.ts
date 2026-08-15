import type { ClaudeAccount, ClaudeUsageWindow } from "@terminaldb/protocol";

export const CLAUDE_USAGE_LABELS = ["5h", "7d", "Fable"] as const;

function accountSortKey(account: ClaudeAccount): string {
  return [account.label, account.email ?? "", account.plan ?? "", account.id]
    .join("\u0000")
    .toLocaleLowerCase();
}

/**
 * Inventory refreshes may finish in a different order. Keep the picker in a
 * deterministic order so a row never moves under the user's pointer.
 */
export function stableClaudeAccounts(
  accounts: readonly ClaudeAccount[],
): readonly ClaudeAccount[] {
  return [...accounts].sort((left, right) =>
    accountSortKey(left).localeCompare(accountSortKey(right)));
}

/** Always reserves the same three usage slots, even during a partial refresh. */
export function stableClaudeUsage(
  account: ClaudeAccount,
): readonly (ClaudeUsageWindow | undefined)[] {
  return CLAUDE_USAGE_LABELS.map((label) =>
    account.usage.find((usage) => usage.label === label));
}
