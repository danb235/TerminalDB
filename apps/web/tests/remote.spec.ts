import AxeBuilder from "@axe-core/playwright";
import { expect, test, type Page } from "@playwright/test";

function freshAccessToken(label: string): string {
  const claims = btoa(JSON.stringify({ iat: Math.floor(Date.now() / 1_000) }))
    .replace(/\+/gu, "-")
    .replace(/\//gu, "_")
    .replace(/=+$/gu, "");
  return `${label}.${claims}.signature`;
}

async function openTerminal(page: Page): Promise<void> {
  await page.goto("/");
  await expect(page.locator(".terminal-stage")).toBeVisible();
  await expect(page.getByRole("button", { name: /^LIVE/ })).toBeVisible();
  await expect(page.locator(".terminal-pane.active .xterm-helper-textarea")).toBeAttached();
}

async function openLab(page: Page): Promise<void> {
  await page.getByRole("button", { name: "Back to sessions" }).click();
  await page.getByRole("button", { name: "Lab" }).click();
  await expect(page.getByRole("heading", { name: "Failure states" })).toBeVisible();
}

async function terminalGeometry(page: Page) {
  return page.evaluate(() => {
    const stage = document.querySelector<HTMLElement>(".terminal-stage");
    const view = document.querySelector<HTMLElement>(".terminal-view");
    if (!stage || !view) throw new Error("Terminal stage is missing");
    const stageRect = stage.getBoundingClientRect();
    const viewRect = view.getBoundingClientRect();
    return {
      scrollX: window.scrollX,
      scrollY: window.scrollY,
      viewportWidth: window.innerWidth,
      viewportHeight: window.innerHeight,
      documentWidth: document.documentElement.scrollWidth,
      documentHeight: document.documentElement.scrollHeight,
      stage: {
        x: stageRect.x,
        y: stageRect.y,
        width: stageRect.width,
        height: stageRect.height,
      },
      view: {
        x: viewRect.x,
        y: viewRect.y,
        width: viewRect.width,
        height: viewRect.height,
      },
    };
  });
}

test.beforeEach(async ({ page }) => {
  await openTerminal(page);
});

test("opens directly into a stable mirrored terminal", async ({ page }) => {
  await expect(page.getByRole("tab", { name: /^meridian /u })).toHaveAttribute(
    "aria-selected",
    "true",
  );
  await expect(page.locator(".terminal-statusbar")).toContainText("claude");
  const viewportStatus = page.locator('.terminal-statusbar span[title^="Web viewport"]');
  await expect(viewportStatus).toHaveAttribute("title", "Web viewport; Mac PTY 100×24");
  await expect(viewportStatus).toHaveText(/^\d+×\d+$/u);
  await expect(page.locator(".terminal-pane.active .xterm-screen")).toBeVisible();

  const geometry = await terminalGeometry(page);
  expect(geometry.scrollX).toBe(0);
  expect(geometry.scrollY).toBe(0);
  expect(geometry.documentWidth).toBeLessThanOrEqual(geometry.viewportWidth);
  expect(geometry.documentHeight).toBe(geometry.viewportHeight);
  expect(geometry.view.height).toBe(geometry.viewportHeight);
});

test("shows a stable subscription list selected independently for each terminal tab", async ({ page }) => {
  await page.getByRole("button", { name: "Accounts", exact: true }).click();
  const picker = page.getByRole("radiogroup", {
    name: "Claude subscription for this terminal tab",
  });
  await expect(picker).toBeVisible();
  const rows = picker.locator("label.account-row");
  await expect(rows).toHaveCount(2);
  await expect(rows.nth(0)).toContainText("Personal");
  await expect(rows.nth(1)).toContainText("SQAD Teams");
  await expect(page.getByRole("radio", { name: "SQAD Teams: Active on this tab" }))
    .toBeChecked();
  await expect(rows.locator(".account-usage")).toHaveCount(6);

  const firstLayout = await rows.evaluateAll((elements) =>
    elements.map((element) => {
      const rect = element.getBoundingClientRect();
      return { top: rect.top, height: rect.height };
    }));
  expect(firstLayout[0]?.height).toBe(firstLayout[1]?.height);

  await page.getByRole("button", { name: "Close panel" }).click();
  await page.getByRole("tab", { name: /^auth test failure /u }).click();
  await page.getByRole("button", { name: "Accounts", exact: true }).click();
  await expect(page.getByRole("radio", { name: "Personal: Active on this tab" }))
    .toBeChecked();
  await expect(rows.nth(0)).toContainText("Personal");
  await expect(rows.nth(1)).toContainText("SQAD Teams");

  await page.getByRole("radio", { name: "SQAD Teams: Use on this tab" }).click();
  await expect(page.getByRole("radio", { name: "SQAD Teams: Active on this tab" }))
    .toBeChecked();
  await expect.poll(() => page.evaluate(() => (
    (window as Window & { __terminaldbMockAccountCommands?: string[] })
      .__terminaldbMockAccountCommands ?? []
  ))).toEqual(["switch:tab_tests:account_team"]);
  await expect(rows.nth(0)).toContainText("Personal");
  await expect(rows.nth(1)).toContainText("SQAD Teams");
});

test("keeps the project directory and active Claude model persistently visible", async ({ page }) => {
  const context = page.locator(".terminal-window-context");
  await expect(context).toContainText("~/dev/meridian");
  await expect(context).toContainText("Opus 5 (1M context)");
  await expect(page.locator(".terminal-statusbar .status-directory")).toHaveText(
    "~/dev/meridian",
  );
  await expect(page.locator(".terminal-statusbar .status-model")).toHaveText(
    "Opus 5 (1M context)",
  );

  const selectedTab = page.locator(
    '.terminal-tab-track button[role="tab"][aria-selected="true"]',
  );
  await expect(selectedTab).toContainText("~/dev/meridian");
  await expect(selectedTab).toContainText("Opus 5 (1M context)");

  await page.evaluate(() => {
    (window as Window & {
      __terminaldbMockOutput?: (output: {
        tabId: string;
        text: string;
        viewport: boolean;
        rows: number;
        columns: number;
      }) => void;
    }).__terminaldbMockOutput?.({
      tabId: "tab_meridian",
      text: "\u001b[2J\u001b[Hlong-running Claude conversation\r\n".repeat(80),
      viewport: true,
      rows: 24,
      columns: 100,
    });
  });

  await expect(context).toContainText("~/dev/meridian");
  await expect(context).toContainText("Opus 5 (1M context)");
});

test("terminal history never scrolls or shrinks the browser document", async ({ page }) => {
  const input = page.locator(".terminal-pane.active .xterm-helper-textarea");
  const before = await terminalGeometry(page);
  await input.focus();
  await page.keyboard.press("Shift+PageUp");
  await page.mouse.wheel(0, -1200);
  const after = await terminalGeometry(page);

  expect(after.scrollY).toBe(0);
  expect(after.documentHeight).toBe(after.viewportHeight);
  expect(after.stage).toEqual(before.stage);
  expect(after.view).toEqual(before.view);
});

test("connectivity maintenance stays in the background without stealing input", async ({ page }) => {
  const liveGeometry = await terminalGeometry(page);
  await openLab(page);
  await page.getByRole("button", { name: "resyncing", exact: true }).click();
  await page.getByRole("button", { name: "Terminal" }).click();

  await expect(page.locator(".connection-overlay")).toHaveCount(0);
  await expect(page.locator(".terminal-pane.active .xterm-host")).toHaveAttribute(
    "aria-disabled",
    "false",
  );
  expect((await terminalGeometry(page)).stage).toEqual(liveGeometry.stage);

  const terminalInput = page.locator(".terminal-pane.active .xterm-helper-textarea");
  await terminalInput.focus();
  await page.keyboard.type("typing-stays-live");
  await expect.poll(() => page.evaluate(() => (
    (window as Window & { __terminaldbMockInputs?: string[] })
      .__terminaldbMockInputs?.join("") ?? ""
  ))).toContain("typing-stays-live");
  await expect(page.getByRole("button", { name: /^LIVE/ })).toBeVisible();
  await expect(terminalInput).toBeFocused();
  expect((await terminalGeometry(page)).stage).toEqual(liveGeometry.stage);
});

test("provides immediate raw terminal keyboard behavior", async ({ page }) => {
  const terminalInput = page.locator(".terminal-pane.active .xterm-helper-textarea");
  await terminalInput.focus();
  await page.keyboard.type("ls -al");
  await page.keyboard.press("Enter");
  await page.keyboard.press("ArrowUp");
  await expect.poll(() => page.evaluate(() => (
    (window as Window & { __terminaldbMockInputs?: string[] })
      .__terminaldbMockInputs?.join("") ?? ""
  ))).toBe("ls -al\r\u001b[A");

  const batches = await page.evaluate(() => (
    (window as Window & { __terminaldbMockInputs?: string[] })
      .__terminaldbMockInputs ?? []
  ));
  expect(batches.join("")).toBe("ls -al\r\u001b[A");

  const armCtrlC = page.getByRole("button", { name: "Arm Ctrl-C" });
  if (await armCtrlC.isVisible()) {
    await armCtrlC.click();
    await page.getByRole("button", { name: "Confirm Ctrl-C" }).click();
  } else {
    await terminalInput.focus();
    await page.keyboard.press("Control+c");
  }
  await expect.poll(() => page.evaluate(() => {
    const sent = (window as Window & { __terminaldbMockInputs?: string[] })
      .__terminaldbMockInputs?.join("") ?? "";
    return [...sent].filter((character) => character === "\u0003").length;
  })).toBe(1);
});

test("keeps slowly typed characters ordered when Return outruns relay acknowledgements", async ({ page }) => {
  await page.evaluate(() => {
    (window as Window & { __terminaldbMockAckDelayMs?: number })
      .__terminaldbMockAckDelayMs = 350;
  });
  const terminalInput = page.locator(".terminal-pane.active .xterm-helper-textarea");
  await terminalInput.focus();

  await page.keyboard.type("p");
  await page.waitForTimeout(230);
  await page.keyboard.type("w");
  await page.waitForTimeout(230);
  await page.keyboard.type("d");
  await page.keyboard.press("Enter");

  await expect.poll(() => page.evaluate(() => (
    (window as Window & { __terminaldbMockInputs?: string[] })
      .__terminaldbMockInputs?.join("") ?? ""
  )), { timeout: 150 }).toBe("pwd\r");

  const batches = await page.evaluate(() => (
    (window as Window & { __terminaldbMockInputs?: string[] })
      .__terminaldbMockInputs ?? []
  ));
  expect(batches).toEqual(["p", "w", "d\r"]);
});

test("never lets optimistic Backspace erase the shell prompt", async ({ page }) => {
  await page.evaluate(() => {
    (window as Window & { __terminaldbMockEchoDelayMs?: number })
      .__terminaldbMockEchoDelayMs = 2_000;
  });
  const terminalInput = page.locator(".terminal-pane.active .xterm-helper-textarea");
  const host = page.locator(".terminal-pane.active .xterm-host");
  const terminalText = () => page.evaluate(() => (
    (window as Window & {
      __terminaldbMockTerminalText?: (tabId: string) => string;
    }).__terminaldbMockTerminalText?.("tab_meridian") ?? ""
  ));
  await terminalInput.focus();
  const initialLine = (await terminalText()).split("\n").at(-1);

  for (let index = 0; index < 5; index += 1) {
    await page.keyboard.press("Backspace");
  }
  expect((await terminalText()).split("\n").at(-1)?.trimEnd())
    .toBe(initialLine?.trimEnd());
  await expect(host).toHaveAttribute("data-editable-cells", "0");

  await page.keyboard.type("pwd");
  await expect.poll(async () => (await terminalText()).split("\n").at(-1))
    .toContain("pwd");
  for (let index = 0; index < 5; index += 1) {
    await page.keyboard.press("Backspace");
  }
  expect((await terminalText()).split("\n").at(-1)?.trimEnd())
    .toBe(initialLine?.trimEnd());
  await expect(host).toHaveAttribute("data-editable-cells", "0");
});

test("paints safe input immediately and reconciles the delayed PTY echo once", async ({ page }) => {
  await page.evaluate(() => {
    (window as Window & { __terminaldbMockEchoDelayMs?: number })
      .__terminaldbMockEchoDelayMs = 600;
  });
  const terminalInput = page.locator(".terminal-pane.active .xterm-helper-textarea");
  const host = page.locator(".terminal-pane.active .xterm-host");
  await terminalInput.focus();
  await page.keyboard.type("TDB_OPTIMISTIC_INPUT");

  await expect(host).not.toHaveAttribute("data-optimistic-pending", "0");
  await expect.poll(() => page.evaluate(() => (
    (window as Window & {
      __terminaldbMockTerminalText?: (tabId: string) => string;
    }).__terminaldbMockTerminalText?.("tab_meridian") ?? ""
  ))).toContain("TDB_OPTIMISTIC_INPUT");

  await expect.poll(() => page.evaluate(() => (
    (window as Window & { __terminaldbMockInputs?: string[] })
      .__terminaldbMockInputs?.join("") ?? ""
  ))).toBe("TDB_OPTIMISTIC_INPUT");
  await expect(host).toHaveAttribute("data-optimistic-pending", "0", {
    timeout: 2_000,
  });
  const viewport = await page.evaluate(() => (
    (window as Window & {
      __terminaldbMockTerminalText?: (tabId: string) => string;
    }).__terminaldbMockTerminalText?.("tab_meridian") ?? ""
  ));
  expect(viewport.match(/TDB_OPTIMISTIC_INPUT/gu)).toHaveLength(1);
});

test("keeps application-mode input visible until an authoritative redraw", async ({ page }) => {
  await page.evaluate(() => {
    const mockWindow = window as Window & {
      __terminaldbMockEchoDelayMs?: number;
      __terminaldbMockOutput?: (output: {
        tabId: string;
        text: string;
        viewport: boolean;
        rows: number;
        columns: number;
        inputMode: "application";
      }) => void;
    };
    const host = document.querySelector<HTMLElement>(
      ".terminal-pane.active .xterm-host",
    );
    mockWindow.__terminaldbMockEchoDelayMs = 300;
    mockWindow.__terminaldbMockOutput?.({
      tabId: "tab_meridian",
      text: "Claude prompt\r\n\u001b[2;1H",
      viewport: true,
      rows: Number(host?.dataset.rows),
      columns: Number(host?.dataset.columns),
      inputMode: "application",
    });
  });
  const terminalInput = page.locator(".terminal-pane.active .xterm-helper-textarea");
  const host = page.locator(".terminal-pane.active .xterm-host");
  await terminalInput.focus();
  await page.keyboard.type("optimistic claude draft");
  await expect(host).not.toHaveAttribute("data-optimistic-pending", "0");
  await expect(page.locator(".terminal-pane.active .optimistic-input-overlay"))
    .toContainText("optimistic claude draft");

  // Application frames must keep flowing underneath local prediction. The
  // previous renderer froze every incremental frame until typing settled.
  await page.evaluate(() => {
    (window as Window & {
      __terminaldbMockOutput?: (output: {
        tabId: string;
        text: string;
        viewport: boolean;
        rows: number;
        columns: number;
        inputMode: "application";
      }) => void;
    }).__terminaldbMockOutput?.({
      tabId: "tab_meridian",
      text: "\r\nAUTHORITATIVE-FRAME-STAYED-LIVE\r\n",
      viewport: false,
      rows: 24,
      columns: 100,
      inputMode: "application",
    });
  });
  await expect.poll(() => page.evaluate(() => (
    (window as Window & {
      __terminaldbMockTerminalText?: (tabId: string) => string;
    }).__terminaldbMockTerminalText?.("tab_meridian") ?? ""
  ))).toContain("AUTHORITATIVE-FRAME-STAYED-LIVE");
  // Printable input is intentionally coalesced before it is sent. Wait past
  // both the batching window and the simulated PTY echo so this assertion
  // exercises the application-mode reconciliation rather than a timer race.
  await page.waitForTimeout(650);
  await expect.poll(() => page.evaluate(() => (
    (window as Window & {
      __terminaldbMockTerminalText?: (tabId: string) => string;
    }).__terminaldbMockTerminalText?.("tab_meridian") ?? ""
  ))).toContain("optimistic claude draft");

  await page.evaluate(() => {
    const host = document.querySelector<HTMLElement>(
      ".terminal-pane.active .xterm-host",
    );
    (window as Window & {
      __terminaldbMockOutput?: (output: {
        tabId: string;
        text: string;
        viewport: boolean;
        rows: number;
        columns: number;
        inputMode: "application";
      }) => void;
    }).__terminaldbMockOutput?.({
      tabId: "tab_meridian",
      text: "Claude prompt\r\noptimistic claude draft\u001b[2;24H",
      viewport: true,
      rows: Number(host?.dataset.rows),
      columns: Number(host?.dataset.columns),
      inputMode: "application",
    });
  });
  await expect(host).toHaveAttribute("data-optimistic-pending", "0");
  const viewport = await page.evaluate(() => (
    (window as Window & {
      __terminaldbMockTerminalText?: (tabId: string) => string;
    }).__terminaldbMockTerminalText?.("tab_meridian") ?? ""
  ));
  expect(viewport.match(/optimistic claude draft/gu)).toHaveLength(1);
});

test("does not paint characters while the Mac reports secure input", async ({ page }) => {
  await page.evaluate(() => {
    const mockWindow = window as Window & {
      __terminaldbMockEchoDelayMs?: number;
      __terminaldbMockOutput?: (output: {
        tabId: string;
        text: string;
        viewport: boolean;
        rows: number;
        columns: number;
        inputMode: "secure";
      }) => void;
    };
    mockWindow.__terminaldbMockEchoDelayMs = 1_000;
    mockWindow.__terminaldbMockOutput?.({
      tabId: "tab_meridian",
      text: "Password: \u001b[1;11H",
      viewport: true,
      rows: 24,
      columns: 100,
      inputMode: "secure",
    });
  });
  const terminalInput = page.locator(".terminal-pane.active .xterm-helper-textarea");
  const host = page.locator(".terminal-pane.active .xterm-host");
  await terminalInput.focus();
  await page.keyboard.type("never-render-this-secret");
  await expect(host).toHaveAttribute("data-input-mode", "secure");
  await expect(host).toHaveAttribute("data-optimistic-pending", "0");
  const viewport = await page.evaluate(() => (
    (window as Window & {
      __terminaldbMockTerminalText?: (tabId: string) => string;
    }).__terminaldbMockTerminalText?.("tab_meridian") ?? ""
  ));
  expect(viewport).not.toContain("never-render-this-secret");
});

test("rolls speculative text back when delivery cannot be confirmed", async ({ page }) => {
  await page.evaluate(() => {
    (window as Window & { __terminaldbMockEchoDelayMs?: number })
      .__terminaldbMockEchoDelayMs = 2_000;
  });
  const terminalInput = page.locator(".terminal-pane.active .xterm-helper-textarea");
  const host = page.locator(".terminal-pane.active .xterm-host");
  await terminalInput.focus();
  await page.keyboard.type("TDB_ROLLBACK_GHOST");
  await expect(host).not.toHaveAttribute("data-optimistic-pending", "0");

  await page.evaluate(() => {
    (window as Window & {
      __terminaldbMockRollbackInput?: (tabId: string) => void;
    }).__terminaldbMockRollbackInput?.("tab_meridian");
  });
  await expect(host).toHaveAttribute("data-optimistic-pending", "0");
  await expect.poll(() => page.evaluate(() => (
    (window as Window & {
      __terminaldbMockTerminalText?: (tabId: string) => string;
    }).__terminaldbMockTerminalText?.("tab_meridian") ?? ""
  ))).not.toContain("TDB_ROLLBACK_GHOST");
});

test("retains independent terminal and follow state for every tab", async ({ page }) => {
  const firstTab = page.getByRole("tab", { name: /^meridian /u });
  const secondTab = page.getByRole("tab", { name: /deploy@prod-web-1/ });
  const firstInput = page.locator(".terminal-pane.active .xterm-helper-textarea");
  await firstInput.focus();
  await page.keyboard.press("Shift+PageUp");
  await expect(page.getByRole("button", { name: "Jump to latest" })).toBeVisible();

  await secondTab.click();
  await expect(secondTab).toHaveAttribute("aria-selected", "true");
  await expect(page.getByRole("button", { name: "Jump to latest" })).toBeHidden();
  expect(await page.locator(".terminal-pane").count()).toBe(3);
  expect(await page.locator(".terminal-pane.active").count()).toBe(1);

  await firstTab.click();
  await expect(page.getByRole("button", { name: "Jump to latest" })).toBeVisible();
});

test("creates, selects, works in, and closes native-backed tabs", async ({ page }) => {
  const initialTabs = page.getByRole("tab");
  await expect(initialTabs).toHaveCount(3);
  await expect(page.getByRole("button", { name: "Close meridian" })).toBeDisabled();

  const deployTab = page.getByRole("tab", { name: /deploy@prod-web-1/ });
  await deployTab.click();
  await expect(deployTab).toHaveAttribute("aria-selected", "true");
  await expect.poll(() => page.evaluate(() => (
    (window as Window & { __terminaldbMockTabCommands?: string[] })
      .__terminaldbMockTabCommands ?? []
  ))).toContain("select:tab_deploy");

  await page.getByRole("button", { name: "New terminal tab" }).click();
  await expect(page.getByRole("tab")).toHaveCount(4);
  const createdTab = page.getByRole("tab", { name: /^zsh/u });
  await expect(createdTab).toHaveAttribute("aria-selected", "true");
  await expect.poll(() => page.evaluate(() => (
    (window as Window & { __terminaldbMockTabCommands?: string[] })
      .__terminaldbMockTabCommands ?? []
  ))).toContain("create:tab_deploy");

  const input = page.locator(".terminal-pane.active .xterm-helper-textarea");
  await input.focus();
  await page.keyboard.type("echo tab-parity");
  await page.keyboard.press("Enter");
  await expect.poll(() => page.evaluate(() => (
    (window as Window & { __terminaldbMockInputs?: string[] })
      .__terminaldbMockInputs?.join("") ?? ""
  ))).toContain("echo tab-parity\r");

  await page.getByRole("button", { name: "Close zsh" }).click();
  await expect(page.getByRole("tab")).toHaveCount(3);
  await expect(deployTab).toHaveAttribute("aria-selected", "true");
  await expect.poll(() => page.evaluate(() => (
    (window as Window & { __terminaldbMockTabCommands?: string[] })
      .__terminaldbMockTabCommands ?? []
  ))).toContainEqual(expect.stringMatching(/^close:tab_mock_/u));
});

test("copies plain terminal text without ANSI control sequences", async ({ page, context }) => {
  await context.grantPermissions(["clipboard-read", "clipboard-write"]);
  await page.getByRole("button", { name: "Copy screen" }).click();
  const copied = await page.evaluate(() => navigator.clipboard.readText());
  expect(copied.length).toBeGreaterThan(10);
  expect(copied).not.toContain("\u001b");
  expect(copied).toContain("refresh-token TTL");
});

test("renders the native Graphite Ledger terminal palette exactly", async ({ page }) => {
  await page.evaluate(() => {
    const mockWindow = window as Window & {
      __terminaldbMockOutput?: (output: {
        tabId: string;
        text: string;
        viewport: boolean;
        rows: number;
        columns: number;
      }) => void;
    };
    mockWindow.__terminaldbMockOutput?.({
      tabId: "tab_meridian",
      text: [
        "\u001b[0m\u001b[2J\u001b[H",
        "\u001b[38;2;82;208;221mApplications\u001b[0m\r\n",
        "\u001b[38;2;180;227;77mEXIT 0\u001b[0m\r\n",
        "\u001b[4;38;2;82;208;221m[DETAILS]\u001b[0m\r\n",
        "\u001b[38;2;167;139;212mtmp\u001b[0m\r\n",
        "\u001b[92mBRIGHT GREEN\u001b[0m",
      ].join(""),
      viewport: true,
      rows: 24,
      columns: 100,
    });
  });

  await expect.poll(() => page.evaluate(() => {
    const spans = Array.from(document.querySelectorAll<HTMLElement>(
      ".terminal-pane.active .xterm-rows span",
    ));
    const styleFor = (text: string) => {
      const element = spans.find((span) => span.textContent?.includes(text));
      if (!element) return undefined;
      const style = getComputedStyle(element);
      return { color: style.color, decoration: style.textDecorationLine };
    };
    return {
      directory: styleFor("Applications")?.color,
      success: styleFor("EXIT 0")?.color,
      details: styleFor("[DETAILS]"),
      path: styleFor("tmp")?.color,
      bright: styleFor("BRIGHT GREEN")?.color,
    };
  })).toEqual({
    directory: "rgb(82, 208, 221)",
    success: "rgb(180, 227, 77)",
    details: {
      color: "rgb(82, 208, 221)",
      decoration: "underline",
    },
    path: "rgb(167, 139, 212)",
    bright: "rgb(199, 240, 98)",
  });
});

test("keeps fixed type while negotiating the PTY grid with the browser", async ({ page }) => {
  const host = page.locator(".terminal-pane.active .xterm-host");
  const viewportStatus = page.locator('.terminal-statusbar span[title^="Web viewport"]');
  await expect(host).toHaveAttribute("data-font-size", "13.5");
  await expect(viewportStatus).toHaveAttribute("title", "Web viewport; Mac PTY 100×24");
  await expect(page.getByRole("button", { name: "Native", exact: true })).toHaveCount(0);
  await expect(page.getByRole("button", { name: "Fit", exact: true })).toHaveCount(0);

  const dimensions = async () => ({
    columns: Number(await host.getAttribute("data-columns")),
    rows: Number(await host.getAttribute("data-rows")),
  });
  const before = await dimensions();
  expect(before.columns).toBeGreaterThan(0);
  expect(before.rows).toBeGreaterThan(0);
  await expect.poll(() => page.evaluate(() => {
    const commands = (window as Window & {
      __terminaldbMockResizeCommands?: Array<{
        tabId: string;
        columns: number;
        rows: number;
      }>;
    }).__terminaldbMockResizeCommands ?? [];
    return commands.at(-1);
  })).toEqual({ tabId: "tab_meridian", ...before });

  await page.evaluate(() => {
    const mockWindow = window as Window & {
      __terminaldbMockOutput?: (output: {
        tabId: string;
        text: string;
        viewport: boolean;
        rows: number;
        columns: number;
      }) => void;
    };
    mockWindow.__terminaldbMockOutput?.({
      tabId: "tab_meridian",
      text: "",
      viewport: false,
      rows: 8,
      columns: 40,
    });
  });
  await expect(viewportStatus).toHaveAttribute("title", "Web viewport; Mac PTY 40×8");
  await expect.poll(async () => dimensions()).toEqual(before);
  await expect(host).toHaveAttribute("data-font-size", "13.5");

  const initialViewport = page.viewportSize();
  if (!initialViewport) throw new Error("Browser viewport is missing");
  await page.setViewportSize({
    width: Math.max(320, Math.floor(initialViewport.width * 0.75)),
    height: Math.max(480, Math.floor(initialViewport.height * 0.75)),
  });
  await expect.poll(async () => (await dimensions()).columns).toBeLessThan(before.columns);
  await expect.poll(async () => (await dimensions()).rows).toBeLessThan(before.rows);
  const smaller = await dimensions();
  await expect.poll(() => page.evaluate(() => {
    const commands = (window as Window & {
      __terminaldbMockResizeCommands?: Array<{
        tabId: string;
        columns: number;
        rows: number;
      }>;
    }).__terminaldbMockResizeCommands ?? [];
    return commands.at(-1);
  })).toEqual({ tabId: "tab_meridian", ...smaller });
  await expect(host).toHaveAttribute("data-font-size", "13.5");
  await expect(viewportStatus).toHaveAttribute("title", "Web viewport; Mac PTY 40×8");

  await page.setViewportSize(initialViewport);
  await expect.poll(async () => (await dimensions()).columns).toBeGreaterThan(smaller.columns);
  await expect.poll(async () => (await dimensions()).rows).toBeGreaterThan(smaller.rows);
  await expect(host).toHaveAttribute("data-font-size", "13.5");

  const layout = await page.evaluate(() => {
    const stage = document.querySelector<HTMLElement>(".terminal-stage")?.getBoundingClientRect();
    const terminalHost = document.querySelector<HTMLElement>(".terminal-pane.active .xterm-host")
      ?.getBoundingClientRect();
    const screen = document.querySelector<HTMLElement>(".terminal-pane.active .xterm-screen")
      ?.getBoundingClientRect();
    if (!stage || !terminalHost || !screen) throw new Error("Terminal layout is missing");
    return {
      stage: { width: stage.width, bottom: stage.bottom },
      host: { width: terminalHost.width },
      screen: { width: screen.width, bottom: screen.bottom },
    };
  });
  expect(Math.abs(layout.host.width - layout.stage.width)).toBeLessThanOrEqual(1);
  expect(layout.screen.width).toBeGreaterThan(layout.stage.width * 0.7);
  expect(Math.abs(layout.stage.bottom - layout.screen.bottom)).toBeLessThanOrEqual(16);
  expect((await terminalGeometry(page)).scrollY).toBe(0);
});

test("waits for a matching Claude grid so frames and bottom options stay intact", async ({ page }) => {
  const host = page.locator(".terminal-pane.active .xterm-host");
  const geometry = {
    columns: Number(await host.getAttribute("data-columns")),
    rows: Number(await host.getAttribute("data-rows")),
  };
  expect(geometry.columns).toBeGreaterThan(20);
  expect(geometry.rows).toBeGreaterThan(5);

  await page.evaluate(({ columns, rows }) => {
    (window as Window & {
      __terminaldbMockOutput?: (output: {
        tabId: string;
        text: string;
        viewport: boolean;
        rows: number;
        columns: number;
        inputMode: "application";
      }) => void;
    }).__terminaldbMockOutput?.({
      tabId: "tab_meridian",
      text: "\u001b[2J\u001b[HBROKEN_REFLOW_MUST_NOT_RENDER",
      viewport: true,
      rows,
      columns: columns + 20,
      inputMode: "application",
    });
  }, geometry);
  await expect(host).toHaveAttribute("data-geometry-sync", "pending");
  await expect.poll(() => page.evaluate(() => (
    (window as Window & {
      __terminaldbMockTerminalText?: (tabId: string) => string;
    }).__terminaldbMockTerminalText?.("tab_meridian") ?? ""
  ))).not.toContain("BROKEN_REFLOW_MUST_NOT_RENDER");

  await page.evaluate(({ columns, rows }) => {
    const top = `╭${"─".repeat(columns - 2)}╮`;
    const bottom = `╰${"─".repeat(columns - 2)}╯`;
    const text = [
      "\u001b[2J\u001b[H",
      top,
      `\u001b[2;1H│ Claude Code${" ".repeat(Math.max(0, columns - 14))}│`,
      `\u001b[${Math.max(3, rows - 1)};1H${bottom}`,
      `\u001b[${rows};1H❯ bypass permissions on · ← for agents`,
      `\u001b[${rows};${Math.max(1, columns - 14)}Hhigh · /effort`,
    ].join("");
    (window as Window & {
      __terminaldbMockOutput?: (output: {
        tabId: string;
        text: string;
        viewport: boolean;
        rows: number;
        columns: number;
        inputMode: "application";
      }) => void;
    }).__terminaldbMockOutput?.({
      tabId: "tab_meridian",
      text,
      viewport: true,
      rows,
      columns,
      inputMode: "application",
    });
  }, geometry);
  await expect(host).toHaveAttribute("data-geometry-sync", "ready");
  await expect.poll(() => page.evaluate(() => (
    (window as Window & {
      __terminaldbMockTerminalText?: (tabId: string) => string;
    }).__terminaldbMockTerminalText?.("tab_meridian") ?? ""
  ))).toContain("bypass permissions on");
  await expect.poll(() => page.evaluate(() => (
    (window as Window & {
      __terminaldbMockTerminalText?: (tabId: string) => string;
    }).__terminaldbMockTerminalText?.("tab_meridian") ?? ""
  ))).toContain("high · /effort");
});

test("account and connection controls are sheets over the live terminal", async ({ page }) => {
  const before = await terminalGeometry(page);
  const accountButton = page.getByRole("button", { name: "Accounts", exact: true });
  if (await accountButton.isVisible()) {
    await accountButton.click();
  } else {
    await page.getByRole("button", { name: "Back to sessions" }).click();
    await page.getByRole("button", { name: "Accounts" }).click();
  }
  await expect(page.getByRole("heading", { name: "Accounts", exact: true })).toBeVisible();
  await expect(page.locator(".terminal-stage")).toBeVisible();
  expect((await terminalGeometry(page)).stage).toEqual(before.stage);
  await page.getByRole("button", { name: "Close panel" }).click();
  expect((await terminalGeometry(page)).stage).toEqual(before.stage);

  await page.getByRole("button", { name: "Remote controls" }).click();
  await expect(page.getByRole("heading", { name: "Trusted controllers" })).toBeVisible();
  await expect(page.locator(".terminal-stage")).toBeVisible();
});

test("blocks account switching while the selected tab is busy", async ({ page }) => {
  const accountButton = page.getByRole("button", { name: "Accounts", exact: true });
  if (await accountButton.isVisible()) await accountButton.click();
  else {
    await page.getByRole("button", { name: "Back to sessions" }).click();
    await page.getByRole("button", { name: "Accounts" }).click();
  }
  await expect(page.getByRole("radio", { name: /Tab is busy$/u })).toBeDisabled();
});

test("makes ended controller actions explicit and inert", async ({ page }) => {
  await openLab(page);
  await page.getByRole("button", { name: "remote ended", exact: true }).click();
  await page.getByRole("button", { name: "Devices" }).click();
  await expect(page.getByText("REMOTE ENDED", { exact: true }).last()).toBeVisible();
  await expect(page.getByRole("button", { name: "Controller access ended" })).toBeDisabled();
  await expect(page.getByRole("button", { name: "Session ended" })).toBeDisabled();
});

test("prototypes every required interruption state", async ({ page }) => {
  await openLab(page);
  for (const state of [
    "connecting",
    "live",
    "slow",
    "reconnecting",
    "rotating",
    "phone offline",
    "mac offline",
    "resyncing",
    "delivery uncertain",
    "remote ended",
    "revoked",
    "update required",
  ]) {
    await page.getByRole("button", { name: state, exact: true }).click();
    await expect(page.locator(".state-grid").getByRole("button", { name: state, exact: true }))
      .toHaveClass(/active/);
  }
});

test("terminal and overlay surfaces have no detectable accessibility violations", async ({ page }) => {
  let results = await new AxeBuilder({ page })
    .exclude(".xterm-helper-textarea")
    .analyze();
  expect(results.violations).toEqual([]);

  await page.getByRole("button", { name: "Remote controls" }).click();
  results = await new AxeBuilder({ page })
    .exclude(".xterm-helper-textarea")
    .analyze();
  expect(results.violations).toEqual([]);
});

test("touch controls meet the minimum target size", async ({ page }, testInfo) => {
  test.skip(testInfo.project.name === "desktop", "Desktop hides the mobile key dock");
  const boxes = await page.locator(".quick-keys button").evaluateAll((buttons) =>
    buttons.map((button) => {
      const rect = button.getBoundingClientRect();
      return { width: rect.width, height: rect.height };
    }));
  expect(boxes.length).toBeGreaterThan(0);
  for (const box of boxes) {
    expect(box.width).toBeGreaterThanOrEqual(44);
    expect(box.height).toBeGreaterThanOrEqual(44);
  }
});

test("captures and removes pairing secrets before redemption completes", async ({ page }) => {
  let attempts = 0;
  await page.route("**/api/v1/pairings/pairing_auto/redeem", async (route) => {
    attempts += 1;
    await new Promise((resolve) => setTimeout(resolve, 100));
    await route.fulfill({
      status: 410,
      contentType: "application/json",
      body: JSON.stringify({ error: "Test link consumed" }),
    });
  });
  await page.goto("/pair/pairing_auto#single-use-secret");
  await expect.poll(() => page.url()).not.toContain("#");
  await expect(page.getByText("single-use-secret")).toHaveCount(0);
  await expect.poll(() => attempts).toBe(1);
  await expect(page.getByRole("button", { name: "Try again" })).toBeVisible();
});

test("keeps the unpaired gate within every target viewport", async ({ page }) => {
  await page.goto("/?unpaired=1");
  await expect(page.getByRole("heading", { name: "Open your terminals" })).toBeVisible();
  const sizes = await page.evaluate(() => ({
    viewport: document.documentElement.clientWidth,
    content: document.documentElement.scrollWidth,
  }));
  expect(sizes.content).toBeLessThanOrEqual(sizes.viewport);
});

test("requires a Mac approval for account creation and keeps sign-in available", async ({ page }) => {
  await page.route("**/api/config", async (route) => {
    await route.fulfill({
      contentType: "application/json",
      body: JSON.stringify({
        apiBaseUrl: "",
        websocketUrl: "",
        protocolVersion: 1,
        region: "us-west-2",
        pairingEnabled: true,
        mockMode: true,
        accountAuth: {
          clientId: "web-client",
          domain: "https://login.example.invalid",
          issuer: "https://cognito-idp.us-west-2.amazonaws.com/us-west-2_pool",
          callbackPath: "/auth/callback",
        },
      }),
    });
  });
  await page.route("https://login.example.invalid/**", async (route) => {
    await route.fulfill({ status: 200, contentType: "text/html", body: "Cognito login" });
  });

  await page.goto("/?unpaired=1");
  await expect(page.getByRole("heading", { name: "Sign in to TerminalDB" })).toBeVisible();
  await expect(page.getByRole("button", { name: "Create account", exact: true })).toHaveCount(0);
  await expect(page.getByRole("button", { name: "Sign in", exact: true })).toBeVisible();

  await page.goto("/?unpaired=1&account=create#account-bootstrap=approved-mac-token");
  const appOrigin = new URL(page.url()).origin;
  await expect(page.getByRole("heading", { name: "Create your TerminalDB account" })).toBeVisible();
  await expect.poll(() => page.url()).not.toContain("approved-mac-token");
  await page.getByRole("button", { name: "Create account", exact: true }).click();
  await expect(page.getByRole("heading", { name: "Choose your credentials" })).toBeVisible();
  await expect(page.getByLabel("Username")).toHaveAttribute("autocomplete", "username");
  await expect(page.getByLabel("Password", { exact: true }))
    .toHaveAttribute("autocomplete", "new-password");
  expect(new URL(page.url()).origin).toBe(appOrigin);
  expect(page.url()).not.toContain("approved-mac-token");
  await page.goto("/");
  await page.evaluate(() => sessionStorage.removeItem("terminaldb.account.bootstrap.v1"));
  await page.reload();
  await expect(page.locator(".terminal-stage")).toBeVisible();
  await page.getByRole("button", { name: "Accounts", exact: true }).click();
  await expect(page.getByRole("heading", { name: "Accounts", exact: true })).toBeVisible();
  await expect(page.getByRole("heading", { name: "Sign in to TerminalDB" })).toBeVisible();
  await expect(page.getByRole("button", { name: "Create account with this Mac" })).toBeVisible();
  await expect(page.getByText("Claude accounts & usage")).toBeVisible();
  const sizes = await page.evaluate(() => ({
    viewport: document.documentElement.clientWidth,
    content: document.documentElement.scrollWidth,
  }));
  expect(sizes.content).toBeLessThanOrEqual(sizes.viewport);
});

test("explains the required Mac update instead of waiting on an unsupported account command", async ({ page }) => {
  await page.addInitScript(() => {
    (window as Window & { __terminaldbMockCapabilities?: readonly string[] })
      .__terminaldbMockCapabilities = ["sequenced-input-v1", "causal-input-output-v1"];
  });
  await page.route("**/api/config", async (route) => {
    await route.fulfill({
      contentType: "application/json",
      body: JSON.stringify({
        apiBaseUrl: "",
        websocketUrl: "",
        protocolVersion: 1,
        region: "us-west-2",
        pairingEnabled: true,
        mockMode: true,
        accountAuth: {
          clientId: "web-client",
          domain: "https://login.example.invalid",
          issuer: "https://cognito-idp.us-west-2.amazonaws.com/us-west-2_pool",
          callbackPath: "/auth/callback",
        },
      }),
    });
  });

  await page.reload();
  await expect(page.locator(".terminal-stage")).toBeVisible();
  await page.getByRole("button", { name: "Accounts", exact: true }).click();

  await expect(page.getByRole("alert")).toContainText("Update TerminalDB on this Mac");
  await expect(page.getByRole("alert")).toContainText("v0.3.0 or newer");
  await expect(page.getByRole("button", { name: "Create account with this Mac" })).toHaveCount(0);
  await expect(page.getByRole("button", { name: "Waiting for Mac…" })).toHaveCount(0);
  await expect(page.getByRole("button", { name: "Sign in", exact: true })).toBeEnabled();
  await expect(page.locator(".terminal-stage")).toBeVisible();
});

test("discovers tenant sessions without exposing legacy enrollment codes", async ({ page }) => {
  let controllerRegistration: Record<string, unknown> | undefined;
  await page.addInitScript(() => {
    localStorage.setItem("terminaldb.account.tokens.v1", JSON.stringify({
      accessToken: "account-access-token",
      refreshToken: "account-refresh-token",
      expiresAt: Date.now() + 3_600_000,
    }));
  });
  await page.route("**/api/config", async (route) => {
    await route.fulfill({
      contentType: "application/json",
      body: JSON.stringify({
        apiBaseUrl: "",
        websocketUrl: "/socket",
        protocolVersion: 1,
        region: "us-west-2",
        pairingEnabled: true,
        accountAuth: {
          clientId: "web-client",
          domain: "https://login.example.invalid",
          issuer: "https://issuer.example.invalid/pool",
          callbackPath: "/auth/callback",
        },
      }),
    });
  });
  await page.route("**/api/v1/account/devices", async (route) => {
    expect(route.request().headers().authorization).toBe("Bearer account-access-token");
    await route.fulfill({
      contentType: "application/json",
      body: JSON.stringify({
        devices: [{
          deviceId: "mac-one",
          deviceName: "Studio Mac",
          state: "online",
          lastSeenAt: 1_700_000_000,
          sessionId: "account-session-1234567890",
          generation: 1,
          sessionCreatedAt: 1_700_000_000,
        }],
      }),
    });
  });
  await page.route("**/api/v1/account/sessions/account-session-1234567890/controllers", async (route) => {
    expect(route.request().headers().authorization).toBe("Bearer account-access-token");
    controllerRegistration = route.request().postDataJSON() as Record<string, unknown>;
    await route.fulfill({
      status: 201,
      contentType: "application/json",
      body: JSON.stringify({
        controllerId: "account-controller",
        sessionId: "account-session-1234567890",
        generation: 1,
        protocolVersion: 1,
        keySalt: "account-controller-key-salt",
        macAgreementPublicKey: controllerRegistration.agreementPublicKey,
      }),
    });
  });
  await page.route("**/api/v1/account/tickets", async (route) => {
    expect(route.request().headers().authorization).toBe("Bearer account-access-token");
    expect(route.request().headers()["x-terminaldb-signature"]).toBeTruthy();
    await route.fulfill({
      status: 503,
      contentType: "application/json",
      body: JSON.stringify({ error: "QA stops before a deployed WebSocket" }),
    });
  });

  await page.goto("/?unpaired=1");
  await expect(page.getByRole("heading", { name: "Your Macs" })).toBeVisible();
  await expect(page.getByText("Studio Mac")).toBeVisible();
  await expect(page.getByRole("button", { name: "Copy code" })).toHaveCount(0);
  await page.getByRole("button", { name: /Studio Mac.*Open/u }).click();
  await expect.poll(() => controllerRegistration).toBeTruthy();
  expect(controllerRegistration?.browserId).toBeTruthy();
  expect(controllerRegistration?.signingPublicKey).toMatchObject({
    kty: "EC",
    crv: "P-256",
  });
  expect(controllerRegistration?.agreementPublicKey).toMatchObject({
    kty: "EC",
    crv: "P-256",
  });
  expect(JSON.stringify(controllerRegistration)).not.toContain('"d"');
  const storedAccessMode = await page.evaluate(async () => {
    const database = await new Promise<IDBDatabase>((resolve, reject) => {
      const request = indexedDB.open("terminaldb-remote", 1);
      request.onsuccess = () => resolve(request.result);
      request.onerror = () => reject(request.error);
    });
    return await new Promise<string | undefined>((resolve, reject) => {
      const transaction = database.transaction("keys", "readonly");
      const request = transaction.objectStore("keys").get("controller-session-v1");
      request.onsuccess = () => resolve((request.result as { accessMode?: string } | undefined)?.accessMode);
      request.onerror = () => reject(request.error);
      transaction.oncomplete = () => database.close();
    });
  });
  expect(storedAccessMode).toBe("account");
});

test("returns to sign-in when native account management revokes browser access", async ({ page }) => {
  await page.addInitScript(() => {
    localStorage.setItem("terminaldb.account.tokens.v1", JSON.stringify({
      accessToken: "revoked-account-access-token",
      refreshToken: "revoked-account-refresh-token",
      expiresAt: Date.now() + 3_600_000,
    }));
  });
  await page.route("**/api/config", async (route) => {
    await route.fulfill({
      contentType: "application/json",
      body: JSON.stringify({
        apiBaseUrl: "",
        websocketUrl: "/socket",
        protocolVersion: 1,
        region: "us-west-2",
        pairingEnabled: true,
        accountAuth: {
          clientId: "web-client",
          domain: "https://login.example.invalid",
          issuer: "https://issuer.example.invalid/pool",
          callbackPath: "/auth/callback",
        },
      }),
    });
  });
  await page.route("**/api/v1/account/devices", async (route) => {
    await route.fulfill({
      status: 401,
      contentType: "application/json",
      body: JSON.stringify({ error: "Account credentials changed" }),
    });
  });

  await page.goto("/?unpaired=1");

  await expect(page.getByRole("heading", { name: "Sign in to TerminalDB" })).toBeVisible();
  await expect(page.getByRole("alert")).toHaveText("Account access changed. Sign in again.");
  await expect.poll(() => page.evaluate(() =>
    localStorage.getItem("terminaldb.account.tokens.v1"))).toBeNull();
});

test("completes Mac binding after Cognito login and discovers its account session", async ({ page }) => {
  let completed = false;
  const bootstrapAccessToken = freshAccessToken("bootstrap-access-token");
  await page.addInitScript((accessToken) => {
    localStorage.setItem("terminaldb.account.tokens.v1", JSON.stringify({
      accessToken,
      refreshToken: "bootstrap-refresh-token",
      expiresAt: Date.now() + 3_600_000,
    }));
    sessionStorage.setItem("terminaldb.account.bootstrap.v1", "approved-bootstrap-token");
  }, bootstrapAccessToken);
  await page.route("**/api/config", async (route) => {
    await route.fulfill({
      contentType: "application/json",
      body: JSON.stringify({
        apiBaseUrl: "",
        websocketUrl: "/socket",
        protocolVersion: 1,
        region: "us-west-2",
        pairingEnabled: true,
        accountAuth: {
          clientId: "web-client",
          domain: "https://login.example.invalid",
          issuer: "https://cognito-idp.us-west-2.amazonaws.com/us-west-2_pool",
          callbackPath: "/auth/callback",
        },
      }),
    });
  });
  await page.route("**/api/v1/account/bootstrap/complete", async (route) => {
    expect(route.request().headers().authorization).toBe(`Bearer ${bootstrapAccessToken}`);
    expect(route.request().postDataJSON()).toEqual({
      bootstrapToken: "approved-bootstrap-token",
    });
    completed = true;
    await route.fulfill({
      contentType: "application/json",
      body: JSON.stringify({ completed: true, deviceId: "new-mac" }),
    });
  });
  await page.route("**/api/v1/account/devices", async (route) => {
    await route.fulfill({
      contentType: "application/json",
      body: JSON.stringify({
        devices: completed ? [{
          deviceId: "new-mac",
          deviceName: "Approved Mac",
          state: "online",
          lastSeenAt: 1_800_000_000,
          sessionId: "new-account-session",
          generation: 1,
          sessionCreatedAt: 1_800_000_000,
        }] : [],
      }),
    });
  });

  await page.goto("/?unpaired=1&account=finish");
  await expect.poll(() => completed).toBe(true);
  await expect(page.getByText("Mac enrolled. It will appear online as soon as its encrypted session connects.")).toBeVisible();
  await expect(page.getByText("Approved Mac")).toBeVisible({ timeout: 5_000 });
  await expect.poll(() => page.evaluate(() =>
    sessionStorage.getItem("terminaldb.account.bootstrap.v1"))).toBeNull();
});

test("logs out after explicitly confirmed account deletion", async ({ page }) => {
  let deletedWithAuthorization: string | undefined;
  const deleteAccessToken = freshAccessToken("delete-account-access-token");
  await page.addInitScript((accessToken) => {
    localStorage.setItem("terminaldb.account.tokens.v1", JSON.stringify({
      accessToken,
      refreshToken: "delete-account-refresh-token",
      expiresAt: Date.now() + 3_600_000,
    }));
  }, deleteAccessToken);
  await page.route("**/api/config", async (route) => {
    await route.fulfill({
      contentType: "application/json",
      body: JSON.stringify({
        apiBaseUrl: "",
        websocketUrl: "/socket",
        protocolVersion: 1,
        region: "us-west-2",
        pairingEnabled: true,
        accountAuth: {
          clientId: "web-client",
          domain: "https://login.example.invalid",
          issuer: "https://issuer.example.invalid/pool",
          callbackPath: "/auth/callback",
        },
      }),
    });
  });
  await page.route("**/api/v1/account/devices", async (route) => {
    await route.fulfill({
      contentType: "application/json",
      body: JSON.stringify({ devices: [] }),
    });
  });
  await page.route("**/api/v1/account", async (route) => {
    expect(route.request().method()).toBe("DELETE");
    deletedWithAuthorization = route.request().headers().authorization;
    await route.fulfill({ status: 204, body: "" });
  });
  await page.route("https://login.example.invalid/oauth2/revoke", async (route) => {
    expect(route.request().postData()).toContain("token=delete-account-refresh-token");
    await route.fulfill({ status: 200, body: "" });
  });
  await page.route("https://login.example.invalid/logout?**", async (route) => {
    await route.fulfill({ status: 200, contentType: "text/html", body: "Account logged out" });
  });

  await page.goto("/?unpaired=1");
  await expect(page.getByRole("button", { name: "Log out" })).toBeVisible();
  await page.getByRole("button", { name: "Delete account", exact: true }).click();
  const finalDelete = page.getByRole("button", { name: "Permanently delete account" });
  await expect(finalDelete).toBeDisabled();
  await page.getByLabel("Type DELETE to confirm").fill("DELETE");
  await expect(finalDelete).toBeEnabled();
  const logoutRequest = page.waitForRequest((request) =>
    request.url().startsWith("https://login.example.invalid/logout?"),
  );
  await finalDelete.click();
  await logoutRequest;

  expect(deletedWithAuthorization).toBe(`Bearer ${deleteAccessToken}`);
});
