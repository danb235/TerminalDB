import type { ClaudeAccount, InventoryPayload, RemoteTab } from "@terminaldb/protocol";

export const accounts: ClaudeAccount[] = [
  {
    id: "account_team",
    label: "SQAD Teams",
    email: "developer@example.com",
    plan: "Team",
    signedIn: true,
    usage: [
      { label: "5h", utilization: 15, resetsAt: "Jul 25, 2:50 AM" },
      { label: "7d", utilization: 30, resetsAt: "Jul 30, 2:00 PM" },
      { label: "Fable", utilization: 4 },
    ],
  },
  {
    id: "account_personal",
    label: "Personal",
    email: "personal@example.com",
    plan: "Max",
    signedIn: true,
    usage: [
      { label: "5h", utilization: 62, resetsAt: "Jul 25, 5:12 AM" },
      { label: "7d", utilization: 41, resetsAt: "Jul 31, 9:00 AM" },
      { label: "Fable", utilization: 9 },
    ],
  },
];

export const tabs: RemoteTab[] = [
  {
    id: "tab_meridian",
    instanceId: "instance_primary",
    windowId: "window_main",
    title: "meridian",
    directory: "~/dev/meridian",
    environment: "LOCAL",
    accountId: "account_team",
    accountLabel: "SQAD Teams",
    foregroundProcess: "claude",
    model: "Opus 5 (1M context)",
    inputMode: "echo",
    busy: true,
    claudeState: "attention",
    updatedAt: new Date().toISOString(),
  },
  {
    id: "tab_deploy",
    instanceId: "instance_primary",
    windowId: "window_main",
    title: "deploy@prod-web-1",
    directory: "~/dev/meridian",
    environment: "PRODUCTION",
    accountId: "account_team",
    accountLabel: "SQAD Teams",
    foregroundProcess: "docker compose",
    inputMode: "secure",
    busy: true,
    claudeState: "working",
    updatedAt: new Date().toISOString(),
  },
  {
    id: "tab_tests",
    instanceId: "instance_secondary",
    windowId: "window_tests",
    title: "auth test failure",
    directory: "~/dev/meridian/api",
    environment: "LOCAL",
    accountId: "account_personal",
    accountLabel: "Personal",
    foregroundProcess: "zsh",
    inputMode: "echo",
    busy: false,
    claudeState: "error",
    updatedAt: new Date().toISOString(),
  },
];

export const mockInventory: InventoryPayload = {
  instances: [
    {
      id: "instance_primary",
      name: "TerminalDB · Main",
      host: "Developer’s Mac",
      tabs: tabs.filter((tab) => tab.instanceId === "instance_primary"),
    },
    {
      id: "instance_secondary",
      name: "TerminalDB · Tests",
      host: "Developer’s Mac",
      tabs: tabs.filter((tab) => tab.instanceId === "instance_secondary"),
    },
  ],
  accounts,
  selectedTabId: "tab_meridian",
};

export const terminalFixture = [
  "\u001b[38;2;180;227;77m●\u001b[0m git pull --rebase origin main",
  "Updating 4c2f19a..8e77b02",
  "Fast-forward",
  " api/routes.py     | 18 ++++++++----",
  " api/auth/token.py | 42 +++++++++++++++++++-------",
  " 2 files changed, 44 insertions(+), 16 deletions(-)",
  "",
  ...Array.from({ length: 48 }, (_, index) =>
    `remote parity fixture ${String(index + 1).padStart(2, "0")} · terminal scrollback remains on the Mac`),
  "",
  "\u001b[38;2;239;101;87m●\u001b[0m pytest tests/api -q",
  "............F...",
  "FAILED tests/api/test_auth.py::test_token_refresh",
  "E AssertionError: expected status 200, got 401",
  'E {\"error\":\"invalid_grant\",\"detail\":\"refresh token expired\"}',
  "1 failed, 15 passed in 6.21s",
  "",
  "\u001b[38;2;82;208;221mclaude\u001b[0m",
  "The rebase shortened refresh-token TTL to 15 minutes.",
  "Update the fixture clock, then run the single failing test.",
  "",
  "\u001b[38;2;180;227;77m❯\u001b[0m ",
].join("\r\n");
