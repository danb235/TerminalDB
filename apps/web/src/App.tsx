import {
  PROTOCOL_VERSION,
  type ClaudeAccount,
  type ConnectionState,
  type InventoryPayload,
  type PTYOutputPayload,
  type RemoteTab,
} from "@terminaldb/protocol";
import {
  lazy,
  Suspense,
  useCallback,
  useEffect,
  useReducer,
  useRef,
  useState,
} from "react";

import { clearControllerSession, loadControllerSession } from "./identity";
import { accounts as mockAccounts, mockInventory, terminalFixture } from "./mock-data";
import { AcknowledgedInputQueue } from "./ordered-input";
import {
  controllerDeviceName,
  loadPublicConfiguration,
  redeemPairing,
  RemoteClient,
} from "./remote-client";
import {
  canAcceptTerminalInput,
  connectionLabel,
  connectionReducer,
  initialConnection,
  presentedConnectionState,
  type ConnectionAction,
} from "./state";
import type {
  TerminalSurfaceHandle,
  TerminalUpdate,
} from "./TerminalSurface";
const TerminalSurface = lazy(async () => {
  const module = await import("./TerminalSurface");
  return { default: module.TerminalSurface };
});

type View = "dashboard" | "terminal" | "accounts" | "devices" | "diagnostics" | "lab";

const TERMINAL_INPUT_BATCH_DELAY_MS = 180;

interface TerminalTabSession {
  readonly update: TerminalUpdate;
  readonly followOutput: boolean;
  readonly localColumns?: number;
  readonly localRows?: number;
}

interface PendingTabMutation {
  readonly operationId: string;
  readonly kind: "create" | "close";
  readonly tabId: string;
  readonly instanceId: string;
  readonly beforeTabIds: ReadonlySet<string>;
  readonly fallbackTabId: string | undefined;
  readonly timer: number;
}

interface TabMutationIndicator {
  readonly kind: "create" | "close";
  readonly tabId: string;
}

function emptyTerminalSession(
  id = 0,
  inputMode: TerminalUpdate["inputMode"] = "secure",
): TerminalTabSession {
  return {
    update: {
      id,
      text: "",
      viewport: true,
      rows: 24,
      columns: 100,
      inputMode,
    },
    followOutput: true,
  };
}

const stateTone: Record<ConnectionState, "live" | "context" | "warning" | "danger" | "quiet"> = {
  connecting: "context",
  live: "live",
  slow: "warning",
  reconnecting: "warning",
  rotating: "context",
  "phone-offline": "warning",
  "mac-offline": "danger",
  resyncing: "context",
  "delivery-uncertain": "warning",
  "remote-ended": "quiet",
  revoked: "danger",
  "update-required": "danger",
};

const stateOptions: ConnectionState[] = [
  "connecting",
  "live",
  "slow",
  "reconnecting",
  "rotating",
  "phone-offline",
  "mac-offline",
  "resyncing",
  "delivery-uncertain",
  "remote-ended",
  "revoked",
  "update-required",
];

function relativeAge(timestamp?: number): string {
  if (!timestamp) return "No successful sync";
  const seconds = Math.max(0, Math.round((Date.now() - timestamp) / 1_000));
  if (seconds < 2) return "Updated now";
  if (seconds < 60) return `Last updated ${seconds}s ago`;
  return `Last updated ${Math.round(seconds / 60)}m ago`;
}

function ConnectionPill({
  state,
  onClick,
}: {
  readonly state: ReturnType<typeof useConnectionModel>[0];
  readonly onClick: () => void;
}) {
  const presentedState = presentedConnectionState(state);
  const presentedModel = presentedState === state.state
    ? state
    : { ...state, state: presentedState };
  return (
    <button
      className={`connection-pill tone-${stateTone[presentedState]}`}
      onClick={onClick}
      aria-label={`${connectionLabel(presentedModel)}. Open connection details.`}
    >
      <span className="pulse-dot" />
      {connectionLabel(presentedModel)}
    </button>
  );
}

function useConnectionModel(): [
  typeof initialConnection,
  React.Dispatch<ConnectionAction>,
] {
  return useReducer(connectionReducer, initialConnection);
}

function AppMark() {
  return (
    <div className="app-mark" aria-hidden="true">
      <span>&gt;_</span>
      <i />
      <i />
      <i />
    </div>
  );
}

function AttentionCard({
  tab,
  onOpen,
}: {
  readonly tab: RemoteTab;
  readonly onOpen: () => void;
}) {
  const needsInput = tab.claudeState === "attention";
  return (
    <button className={`attention-card ${needsInput ? "needs-input" : ""}`} onClick={onOpen}>
      <div className="attention-icon">{needsInput ? "?" : "✦"}</div>
      <div>
        <span className="eyebrow">{needsInput ? "CLAUDE NEEDS INPUT" : "CLAUDE SESSION"}</span>
        <strong>{tab.title}</strong>
        <small>
          {needsInput
            ? "Allow Claude to run the read-only test?"
            : `${tab.foregroundProcess ?? "Shell"} is ${tab.busy ? "working" : "ready"}`}
        </small>
      </div>
      <span className="chevron">›</span>
    </button>
  );
}

function SessionCard({
  tab,
  onOpen,
}: {
  readonly tab: RemoteTab;
  readonly onOpen: () => void;
}) {
  const status = tab.claudeState ?? (tab.busy ? "working" : "ready");
  return (
    <button className="session-card" onClick={onOpen}>
      <div className={`session-rail state-${status}`} />
      <div className="session-main">
        <div className="session-title">
          <strong>{tab.title}</strong>
          <span className={`mini-state state-${status}`}>{status.replace("-", " ")}</span>
        </div>
        <code>{tab.directory}</code>
        <div className="session-meta">
          <span>{tab.environment}</span>
          <span>
            {tab.splitDirection
              ? `Split ${tab.splitDirection}`
              : `Window ${tab.windowId}`}
          </span>
          <span>{tab.accountLabel ?? "No Claude account"}</span>
          <span>{tab.foregroundProcess ?? "zsh"}</span>
        </div>
      </div>
      <span className="chevron">›</span>
    </button>
  );
}

function Dashboard({
  inventory,
  onOpenTab,
}: {
  readonly inventory: InventoryPayload;
  readonly onOpenTab: (tab: RemoteTab) => void;
}) {
  const allTabs = inventory.instances.flatMap((instance) => instance.tabs);
  const attention = allTabs.filter((tab) => tab.claudeState === "attention");
  const host = inventory.instances[0]?.host ?? "Your Mac";
  return (
    <main className="view dashboard-view">
      <section className="hero-status">
        <span className="eyebrow">{host.toUpperCase()}</span>
        <div className="hero-line">
          <h1>Remote ledger</h1>
          <span>{allTabs.length} tabs</span>
        </div>
        <p>Claude sessions first. Every open terminal remains one tap away.</p>
      </section>

      {attention.length > 0 ? (
        <section>
          <div className="section-title">
            <span>NEEDS YOU</span>
            <b>{attention.length}</b>
          </div>
          <div className="stack">
            {attention.map((tab) => (
              <AttentionCard key={tab.id} tab={tab} onOpen={() => onOpenTab(tab)} />
            ))}
          </div>
        </section>
      ) : null}

      <section>
        <div className="section-title">
          <span>OPEN TERMINALDB INSTANCES</span>
          <small>Live inventory</small>
        </div>
        <div className="instance-list">
          {inventory.instances.map((instance) => (
            <article className="instance" key={instance.id}>
              <header>
                <div>
                  <strong>{instance.name}</strong>
                  <small>{instance.host}</small>
                </div>
                <span>{instance.tabs.length} tabs</span>
              </header>
              <div className="session-list">
                {instance.tabs.map((tab) => (
                  <SessionCard key={tab.id} tab={tab} onOpen={() => onOpenTab(tab)} />
                ))}
              </div>
            </article>
          ))}
        </div>
      </section>
    </main>
  );
}

function UnpairedView({ checking }: { readonly checking: boolean }) {
  return (
    <main className="pairing-view">
      <AppMark />
      <span className="eyebrow">TERMINALDB REMOTE</span>
      <h1>{checking ? "Checking this browser…" : "Pair from your Mac"}</h1>
      <p>
        {checking
          ? "Looking for a trusted controller identity on this device."
          : "Enable Remote Control in TerminalDB, then open its one-time link or scan its QR code."}
      </p>
      <div className="pairing-proof">
        <div><span>TERMINAL DATA</span><strong>Remains on your Mac</strong></div>
        <div><span>PAIRING</span><strong>Single-use · 10 minutes</strong></div>
        <div><span>SECURITY</span><strong>End-to-end encrypted</strong></div>
      </div>
      <small>No account password or Claude credential is accepted here.</small>
    </main>
  );
}

function TerminalView({
  tab,
  tabs,
  accounts,
  terminalSessions,
  state,
  onSelectTab,
  onCreateTab,
  onCloseTab,
  tabMutation,
  onInput,
  onQuickKey,
  onBack,
  onAccounts,
  onDevices,
  onDiagnostics,
  onCopy,
  onFollowOutputChange,
  onGeometryChange,
  onAuthoritativeRefreshNeeded,
  onSurface,
}: {
  readonly tab: RemoteTab;
  readonly tabs: readonly RemoteTab[];
  readonly accounts: readonly ClaudeAccount[];
  readonly terminalSessions: Readonly<Record<string, TerminalTabSession>>;
  readonly state: ReturnType<typeof useConnectionModel>[0];
  readonly onSelectTab: (tab: RemoteTab) => void;
  readonly onCreateTab: () => void;
  readonly onCloseTab: (tab: RemoteTab) => void;
  readonly tabMutation?: TabMutationIndicator | undefined;
  readonly onInput: (data: string) => void;
  readonly onQuickKey: (key: string) => void;
  readonly onBack: () => void;
  readonly onAccounts: () => void;
  readonly onDevices: () => void;
  readonly onDiagnostics: () => void;
  readonly onCopy: (tabId: string) => void;
  readonly onFollowOutputChange: (tabId: string, following: boolean) => void;
  readonly onGeometryChange: (tabId: string, columns: number, rows: number) => void;
  readonly onAuthoritativeRefreshNeeded: () => void;
  readonly onSurface: (tabId: string, surface: TerminalSurfaceHandle | null) => void;
}) {
  const acceptsInput = canAcceptTerminalInput(state);
  const session = terminalSessions[tab.id] ?? emptyTerminalSession();
  const activeAccount = accounts.find((account) => account.id === tab.accountId);
  const [ctrlCArmed, setCtrlCArmed] = useState(false);
  const [selectionByTab, setSelectionByTab] = useState<Record<string, boolean>>({});
  const ctrlCResetTimer = useRef<number | undefined>(undefined);
  useEffect(() => {
    if (acceptsInput) return;
    setCtrlCArmed(false);
    if (ctrlCResetTimer.current) {
      window.clearTimeout(ctrlCResetTimer.current);
      ctrlCResetTimer.current = undefined;
    }
  }, [acceptsInput]);
  useEffect(
    () => () => {
      if (ctrlCResetTimer.current) {
        window.clearTimeout(ctrlCResetTimer.current);
      }
    },
    [],
  );
  const deliberateCtrlC = () => {
    if (!ctrlCArmed) {
      setCtrlCArmed(true);
      ctrlCResetTimer.current = window.setTimeout(() => {
        setCtrlCArmed(false);
        ctrlCResetTimer.current = undefined;
      }, 3_000);
      return;
    }
    if (ctrlCResetTimer.current) {
      window.clearTimeout(ctrlCResetTimer.current);
      ctrlCResetTimer.current = undefined;
    }
    setCtrlCArmed(false);
    onQuickKey("^C");
  };
  return (
    <main className="terminal-view">
      <div className="terminal-window-bar">
        <button className="terminal-back" onClick={onBack} aria-label="Back to sessions">‹</button>
        <div className="terminal-window-title">
          <strong>{tab.title}</strong>
          <div className="terminal-window-context">
            <code title={tab.directory}>{tab.directory}</code>
            {tab.model ? <span title={`Active Claude model: ${tab.model}`}>{tab.model}</span> : null}
          </div>
        </div>
        <ConnectionPill state={state} onClick={onDiagnostics} />
        <button className="account-chip" onClick={onAccounts} aria-label="Claude account">
          <span aria-hidden="true">●</span>
          <span className="account-chip-label">{tab.accountLabel ?? "No account"}</span>
        </button>
        <button className="terminal-more" onClick={onDevices} aria-label="Remote controls">•••</button>
      </div>

      <div className="terminal-tabs-row">
        <div className="terminal-tab-strip">
          <div className="terminal-tab-track" role="tablist" aria-label="Open TerminalDB tabs">
            {tabs.map((candidate) => {
              const pendingClose =
                tabMutation?.kind === "close" && tabMutation.tabId === candidate.id;
              return (
                <button
                  key={candidate.id}
                  role="tab"
                  aria-selected={candidate.id === tab.id}
                  className={`${candidate.id === tab.id ? "active" : ""} ${pendingClose ? "pending-close" : ""}`}
                  onClick={() => onSelectTab(candidate)}
                >
                  <span className={`tab-state state-${candidate.claudeState ?? "ready"}`} />
                  <strong>{candidate.title}</strong>
                  <code title={candidate.directory}>
                    {candidate.directory}
                    {candidate.model ? ` · ${candidate.model}` : ""}
                  </code>
                </button>
              );
            })}
          </div>
          <div className="terminal-tab-close-track">
            {tabs.map((candidate) => {
              const pendingClose =
                tabMutation?.kind === "close" && tabMutation.tabId === candidate.id;
              const closeUnavailable =
                !acceptsInput || Boolean(tabMutation) || candidate.busy || Boolean(candidate.parentPaneId);
              const closeReason = candidate.parentPaneId
                ? "Split panes are managed inside their desktop tab"
                : candidate.busy
                  ? "Stop the foreground process before closing this tab"
                  : !acceptsInput
                    ? "Reconnect before closing this tab"
                    : "Close tab";
              return (
                <div className={`terminal-tab-close-slot ${pendingClose ? "pending-close" : ""}`} key={candidate.id}>
                <button
                  className="terminal-tab-close"
                  aria-label={`Close ${candidate.title}`}
                  title={closeReason}
                  disabled={closeUnavailable}
                  onClick={() => onCloseTab(candidate)}
                >
                  ×
                </button>
                </div>
              );
            })}
          </div>
        </div>
        <div className="terminal-actions">
          <button
            className="terminal-new-tab"
            aria-label="New terminal tab"
            title="New terminal tab"
            disabled={!acceptsInput || Boolean(tabMutation)}
            onClick={onCreateTab}
          >
            {tabMutation?.kind === "create" ? "…" : "+"}
          </button>
          <button onClick={() => onCopy(tab.id)}>
            {selectionByTab[tab.id] ? "Copy selection" : "Copy screen"}
          </button>
        </div>
      </div>

      <section className="terminal-stage" aria-label="Mirrored TerminalDB session">
        <Suspense fallback={<div className="terminal-loading">Loading terminal viewport…</div>}>
          {tabs.map((candidate) => {
            const candidateSession = terminalSessions[candidate.id] ?? emptyTerminalSession();
            return (
              <TerminalSurface
                key={candidate.id}
                ref={(surface) => onSurface(candidate.id, surface)}
                update={candidateSession.update}
                active={candidate.id === tab.id}
                followOutput={candidateSession.followOutput}
                inputEnabled={acceptsInput && candidate.id === tab.id}
                onInput={onInput}
                onGeometryChange={(columns, rows) =>
                  onGeometryChange(candidate.id, columns, rows)}
                onFollowOutputChange={(following) =>
                  onFollowOutputChange(candidate.id, following)}
                onSelectionChange={(hasSelection) => {
                  setSelectionByTab((current) =>
                    current[candidate.id] === hasSelection
                      ? current
                      : { ...current, [candidate.id]: hasSelection });
                }}
                onAuthoritativeRefreshNeeded={onAuthoritativeRefreshNeeded}
              />
            );
          })}
        </Suspense>

        <button
          className={`jump-latest ${session.followOutput ? "is-hidden" : ""}`}
          onClick={() => onFollowOutputChange(tab.id, true)}
          disabled={session.followOutput}
          aria-hidden={session.followOutput}
        >Jump to latest</button>
      </section>

      <div className="quick-keys" aria-label="Terminal quick keys">
        {["Esc", "Tab", "↑", "↓", "←", "→"].map((key) => (
          <button key={key} onClick={() => onQuickKey(key)} disabled={!acceptsInput}>
            {key}
          </button>
        ))}
        <button
          className={ctrlCArmed ? "danger-armed" : ""}
          onClick={deliberateCtrlC}
          disabled={!acceptsInput}
          aria-label={ctrlCArmed ? "Confirm Ctrl-C" : "Arm Ctrl-C"}
        >
          {ctrlCArmed ? "Confirm ^C" : "^C"}
        </button>
      </div>

      <footer className="terminal-statusbar">
        <span className={`process-state state-${tab.claudeState ?? (tab.busy ? "working" : "ready")}`}>
          {tab.busy ? "●" : "✓"} {tab.foregroundProcess ?? "zsh"}
        </span>
        <span className="status-environment">{tab.environment}</span>
        <span className="status-account">{tab.accountLabel ?? "No Claude account"}</span>
        <span className="status-directory" title={tab.directory}>{tab.directory}</span>
        {tab.model ? <span className="status-model">{tab.model}</span> : null}
        {activeAccount?.usage[0] ? (
          <span className="status-usage">
            {activeAccount.usage[0].label} {activeAccount.usage[0].utilization}%
          </span>
        ) : null}
        <span className="status-spacer" />
        <span title={`Web viewport; Mac PTY ${session.update.columns}×${session.update.rows}`}>
          {session.localColumns ?? session.update.columns}×
          {session.localRows ?? session.update.rows}
        </span>
        <span>{state.rttMs !== undefined ? `${state.rttMs}ms` : "—"}</span>
      </footer>
    </main>
  );
}

function AccountsView({
  accounts,
  selectedTab,
  onSwitch,
  onRefresh,
  refreshing,
  canControl,
}: {
  readonly accounts: readonly ClaudeAccount[];
  readonly selectedTab: RemoteTab | undefined;
  readonly onSwitch: (account: ClaudeAccount) => void;
  readonly onRefresh: () => void;
  readonly refreshing: boolean;
  readonly canControl: boolean;
}) {
  return (
    <section className="view accounts-view" aria-labelledby="accounts-heading">
      <header className="page-heading">
        <span className="eyebrow">CLAUDE CODE</span>
        <h1 id="accounts-heading">Account & usage</h1>
        <p>Switch an account already authenticated on your Mac. Credentials never leave it.</p>
      </header>
      <div className="account-list">
        {accounts.map((account) => {
          const active = account.id === selectedTab?.accountId;
          return (
            <article className={`account-card ${active ? "active" : ""}`} key={account.id}>
              <header>
                <div className="account-avatar">{account.label.slice(0, 2).toUpperCase()}</div>
                <div>
                  <strong>{account.label}</strong>
                  <small>{account.email}</small>
                </div>
                <span>{account.plan}</span>
              </header>
              <div className="usage-grid">
                {account.usage.map((usage) => (
                  <div className="usage" key={usage.label}>
                    <div>
                      <span>{usage.label}</span>
                      <b>{usage.utilization}%</b>
                    </div>
                    <div className="usage-bar">
                      <i style={{ width: `${usage.utilization}%` }} />
                    </div>
                    <small>{usage.resetsAt ? `Resets ${usage.resetsAt}` : "Current allocation"}</small>
                  </div>
                ))}
              </div>
              <button
                className={active ? "secondary-button" : "primary-button"}
                onClick={() => onSwitch(account)}
                disabled={active || selectedTab?.busy || !canControl}
              >
                {active
                  ? "Active on this tab"
                  : selectedTab?.busy
                    ? "Tab is busy"
                    : !canControl
                      ? "Remote unavailable"
                      : "Use on this tab"}
              </button>
            </article>
          );
        })}
      </div>
      <button
        className="wide-secondary"
        onClick={onRefresh}
        disabled={refreshing || !canControl}
      >
        {refreshing ? "Refreshing usage…" : "Refresh usage"}
      </button>
      <p className="privacy-note">Add, remove, and reauthenticate accounts on your Mac.</p>
    </section>
  );
}

function DevicesView({
  state,
  onRevoke,
  onEndSession,
}: {
  readonly state: ReturnType<typeof useConnectionModel>[0];
  readonly onRevoke: () => void;
  readonly onEndSession: () => void;
}) {
  const sessionEnded = ["remote-ended", "revoked", "update-required"].includes(
    state.state,
  );
  const canEndSession = state.state === "live" || state.state === "slow";
  return (
    <section className="view devices-view" aria-labelledby="devices-heading">
      <header className="page-heading">
        <span className="eyebrow">REMOTE CONTROL</span>
        <h1 id="devices-heading">Trusted controllers</h1>
        <p>Pairing grants access only while Remote Control is enabled on your Mac.</p>
      </header>
      <article className="device-card active">
        <div className="device-icon">▯</div>
        <div>
          <strong>This browser</strong>
          <small>
            {sessionEnded
              ? "This controller no longer has remote-session access"
              : "Current encrypted controller · connected now"}
          </small>
          <code>Key stored only on this device</code>
        </div>
        <span>{connectionLabel(state)}</span>
      </article>
      <button className="wide-secondary" onClick={onRevoke} disabled={sessionEnded}>
        {sessionEnded ? "Controller access ended" : "Revoke this browser"}
      </button>
      <p className="privacy-note">Manage and revoke other trusted controllers from TerminalDB on your Mac.</p>
      <section className="risk-panel">
        <strong>End remote session</strong>
        <p>Ends the session and revokes every controller without stopping work on your Mac.</p>
        <button onClick={onEndSession} disabled={!canEndSession}>
          {sessionEnded ? "Session ended" : "End session on Mac"}
        </button>
      </section>
    </section>
  );
}

function DiagnosticsView({
  model,
  region,
  controller,
}: {
  readonly model: ReturnType<typeof useConnectionModel>[0];
  readonly region: string;
  readonly controller: string;
}) {
  return (
    <section className="view diagnostics-view" aria-labelledby="diagnostics-heading">
      <header className="page-heading">
        <span className="eyebrow">CONNECTION DETAILS</span>
        <h1 id="diagnostics-heading">Two-hop health</h1>
        <p>An open socket is not enough. Both paths must be current before input is enabled.</p>
      </header>
      <div className="connection-map" aria-label="Phone to AWS to Mac connection">
        <div className="map-node">
          <b>PHONE</b>
          <span>{controller}</span>
        </div>
        <div className="map-link live">
          <i />
          <span>{model.rttMs ?? 84}ms</span>
        </div>
        <div className="map-node aws">
          <b>AWS</b>
          <span>{region}</span>
        </div>
        <div className={`map-link ${model.state === "mac-offline" ? "failed" : "live"}`}>
          <i />
          <span>{model.state === "mac-offline" ? "stale" : "live"}</span>
        </div>
        <div className="map-node">
          <b>MAC</b>
          <span>TerminalDB</span>
        </div>
      </div>
      <dl className="metric-list">
        <div><dt>Status</dt><dd>{connectionLabel(model)}</dd></div>
        <div><dt>Mac last seen</dt><dd>{relativeAge(model.lastMacSeenAt)}</dd></div>
        <div><dt>Last full sync</dt><dd>{relativeAge(model.lastSyncAt)}</dd></div>
        <div><dt>Reconnect attempt</dt><dd>{model.reconnectAttempt}</dd></div>
        <div><dt>Protocol</dt><dd>v1 · encrypted</dd></div>
        <div><dt>Region</dt><dd>{region}</dd></div>
      </dl>
      <section className="diagnostic-note">
        <span>PRIVACY</span>
        <p>AWS can route this session but cannot read terminal or Claude content.</p>
      </section>
    </section>
  );
}

function LabView({
  model,
  dispatch,
}: {
  readonly model: ReturnType<typeof useConnectionModel>[0];
  readonly dispatch: React.Dispatch<ConnectionAction>;
}) {
  const [rtt, setRtt] = useState(84);
  const applyState = (state: ConnectionState) => {
    dispatch({
      type: "simulate",
      state,
      rttMs: state === "slow" ? Math.max(1_800, rtt) : rtt,
    });
  };
  return (
    <main className="view lab-view">
      <header className="page-heading">
        <span className="eyebrow">CONNECTIVITY LAB</span>
        <h1>Failure states</h1>
        <p>Exercise the exact UI users see under cellular loss and session changes.</p>
      </header>
      <div className={`lab-preview tone-${stateTone[model.state]}`}>
        <ConnectionPill state={model} onClick={() => undefined} />
        <strong>{model.detail ?? "TerminalDB is current and ready for input."}</strong>
        <small>{relativeAge(model.lastSyncAt)}</small>
      </div>
      <label className="range-control">
        <span><b>Round-trip latency</b><output>{rtt}ms</output></span>
        <input type="range" min="20" max="3000" value={rtt} onChange={(event) => setRtt(Number(event.target.value))} />
      </label>
      <div className="state-grid">
        {stateOptions.map((state) => (
          <button className={state === model.state ? "active" : ""} key={state} onClick={() => applyState(state)}>
            {state.replaceAll("-", " ")}
          </button>
        ))}
      </div>
      <section className="lab-sequence">
        <span>RECONNECT CONTRACT</span>
        <ol>
          <li>Freeze the last safe viewport</li>
          <li>Disable input immediately</li>
          <li>Reconnect with full jitter</li>
          <li>Request inventory and viewport</li>
          <li>Enable input only after health ack</li>
        </ol>
      </section>
    </main>
  );
}

function PairingView({
  pairingId,
  onPair,
  error,
  pairing,
}: {
  readonly pairingId: string;
  readonly onPair: () => void;
  readonly error: string | undefined;
  readonly pairing: boolean;
}) {
  return (
    <main className="pairing-view">
      <AppMark />
      <span className="eyebrow">TERMINALDB REMOTE</span>
      <h1>{error ? "Pairing needs attention" : "Opening TerminalDB…"}</h1>
      <p aria-live="polite">
        {error
          ? "The secure link could not be used. Create a new link on your Mac and try again."
          : "Securing this browser and mirroring your open terminal tabs."}
      </p>
      <div className="pairing-proof">
        <div><span>MAC</span><strong>TerminalDB on your Mac</strong></div>
        <div><span>PAIRING ID</span><code>{pairingId.slice(0, 12)}</code></div>
        <div><span>SECURITY</span><strong>End-to-end encrypted</strong></div>
      </div>
      {error ? <div className="pair-error" role="alert">{error}</div> : null}
      {error ? (
        <button className="pair-button" onClick={onPair}>Try again</button>
      ) : (
        <button className="pair-button" disabled>{pairing ? "Connecting…" : "Preparing…"}</button>
      )}
      <small>The link expires after 10 minutes and cannot be used twice.</small>
    </main>
  );
}

export function App() {
  const forceUnpaired =
    import.meta.env.DEV &&
    new URLSearchParams(location.search).has("unpaired");
  const [view, setView] = useState<View>(
    import.meta.env.DEV && !forceUnpaired ? "terminal" : "dashboard",
  );
  const [connection, dispatch] = useConnectionModel();
  const initialInventory: InventoryPayload = import.meta.env.DEV
    ? mockInventory
    : { instances: [], accounts: [] };
  const [inventory, setInventory] = useState<InventoryPayload>(initialInventory);
  const [selectedTabId, setSelectedTabId] = useState(initialInventory.selectedTabId);
  const [terminalSessions, setTerminalSessions] = useState<
    Record<string, TerminalTabSession>
  >(() => {
    const sessions: Record<string, TerminalTabSession> = {};
    for (const tab of initialInventory.instances.flatMap((instance) => instance.tabs)) {
      sessions[tab.id] = emptyTerminalSession(0, tab.inputMode ?? "secure");
    }
    if (initialInventory.selectedTabId && import.meta.env.DEV) {
      sessions[initialInventory.selectedTabId] = {
        update: {
          id: 0,
          text: terminalFixture,
          viewport: true,
          rows: 24,
          columns: 100,
          inputMode: initialInventory.instances
            .flatMap((instance) => instance.tabs)
            .find((tab) => tab.id === initialInventory.selectedTabId)
            ?.inputMode ?? "secure",
        },
        followOutput: true,
      };
    }
    return sessions;
  });
  const [accessState, setAccessState] = useState<"checking" | "paired" | "unpaired">(
    import.meta.env.DEV && !forceUnpaired ? "paired" : "checking",
  );
  const [usageRefreshing, setUsageRefreshing] = useState(false);
  const [tabMutation, setTabMutation] = useState<TabMutationIndicator>();
  const [pairError, setPairError] = useState<string>();
  const [pairing, setPairing] = useState(false);
  const [remoteRegion, setRemoteRegion] = useState("us-west-2");
  const clientRef = useRef<RemoteClient | null>(null);
  const connectionEpochRef = useRef(0);
  const selectedTabRef = useRef(selectedTabId);
  const terminalUpdateIdRef = useRef(0);
  const terminalSurfacesRef = useRef(new Map<string, TerminalSurfaceHandle>());
  const pendingTerminalInputRef = useRef<{ tabId: string; data: string } | undefined>(undefined);
  const terminalInputTimerRef = useRef<number | undefined>(undefined);
  const inputDeliveryQueueRef = useRef<AcknowledgedInputQueue | null>(null);
  if (inputDeliveryQueueRef.current === null) {
    inputDeliveryQueueRef.current = new AcknowledgedInputQueue();
  }
  const pendingTabMutationRef = useRef<PendingTabMutation | undefined>(undefined);
  const pairingAttemptedRef = useRef(false);
  const pathParts = location.pathname.split("/").filter(Boolean);
  const pairingId = pathParts[0] === "pair" ? pathParts[1] : undefined;
  const [pairingSecret] = useState(() => {
    const secret = location.hash.replace(/^#/u, "");
    if (secret) {
      history.replaceState({}, "", `${location.pathname}${location.search}`);
    }
    return secret;
  });

  const allTabs = inventory.instances.flatMap((instance) => instance.tabs);
  const selectedTab =
    allTabs.find((tab) => tab.id === selectedTabId) ?? allTabs[0];

  const applyTerminalOutput = useCallback((nextOutput: PTYOutputPayload) => {
    terminalUpdateIdRef.current += 1;
    setTerminalSessions((current) => {
      const previous = current[nextOutput.tabId] ?? emptyTerminalSession();
      return {
        ...current,
        [nextOutput.tabId]: {
          ...previous,
          update: {
            id: terminalUpdateIdRef.current,
            text: nextOutput.text,
            viewport: nextOutput.viewport,
            rows: nextOutput.rows,
            columns: nextOutput.columns,
            inputMode: nextOutput.inputMode ?? previous.update.inputMode,
          },
        },
      };
    });
  }, []);

  useEffect(() => {
    if (!import.meta.env.DEV) return;
    const mockWindow = window as Window & {
      __terminaldbMockOutput?: (output: PTYOutputPayload) => void;
      __terminaldbMockTerminalText?: (tabId: string) => string;
      __terminaldbMockRollbackInput?: (tabId: string) => void;
    };
    mockWindow.__terminaldbMockOutput = applyTerminalOutput;
    mockWindow.__terminaldbMockTerminalText = (tabId) =>
      terminalSurfacesRef.current.get(tabId)?.getViewportText() ?? "";
    mockWindow.__terminaldbMockRollbackInput = (tabId) =>
      terminalSurfacesRef.current.get(tabId)?.rollbackOptimisticInput();
    return () => {
      delete mockWindow.__terminaldbMockOutput;
      delete mockWindow.__terminaldbMockTerminalText;
      delete mockWindow.__terminaldbMockRollbackInput;
    };
  }, [applyTerminalOutput]);

  useEffect(() => {
    selectedTabRef.current = selectedTabId;
    clientRef.current?.setViewing(
      document.visibilityState === "visible" ? selectedTabId : undefined,
    );
  }, [selectedTabId]);

  useEffect(() => {
    const acceptsInput = canAcceptTerminalInput(connection);
    if (acceptsInput) return;
    if (terminalInputTimerRef.current) {
      window.clearTimeout(terminalInputTimerRef.current);
      terminalInputTimerRef.current = undefined;
    }
    pendingTerminalInputRef.current = undefined;
    inputDeliveryQueueRef.current?.cancelAll();
  }, [connection.state]);

  useEffect(
    () => () => {
      if (terminalInputTimerRef.current) {
        window.clearTimeout(terminalInputTimerRef.current);
      }
      inputDeliveryQueueRef.current?.cancelAll();
    },
    [],
  );

  const clearPendingTabMutation = useCallback((operationId?: string) => {
    const pending = pendingTabMutationRef.current;
    if (!pending || (operationId && pending.operationId !== operationId)) return;
    window.clearTimeout(pending.timer);
    pendingTabMutationRef.current = undefined;
    setTabMutation(undefined);
  }, []);

  useEffect(() => () => {
    const pending = pendingTabMutationRef.current;
    if (pending) window.clearTimeout(pending.timer);
  }, []);

  const connect = useCallback(async () => {
    const epoch = ++connectionEpochRef.current;
    try {
      const configuration = await loadPublicConfiguration();
      if (epoch !== connectionEpochRef.current) return;
      setRemoteRegion(configuration.region);
      if (configuration.protocolVersion !== PROTOCOL_VERSION) {
        setAccessState((await loadControllerSession()) ? "paired" : "unpaired");
        dispatch({ type: "version-mismatch" });
        return;
      }
      if (configuration.mockMode) {
        if (forceUnpaired) {
          setAccessState("unpaired");
          return;
        }
        setAccessState("paired");
        window.setTimeout(() => {
          dispatch({ type: "socket-open" });
          window.setTimeout(() => dispatch({ type: "health", rttMs: 84 }), 450);
          window.setTimeout(() => dispatch({ type: "resync-complete" }), 600);
        }, 250);
        return;
      }
      const client = new RemoteClient({
        onSocketOpen: () => {
          if (epoch === connectionEpochRef.current) dispatch({ type: "socket-open" });
        },
        onSocketClose: (phoneOffline) => {
          if (epoch === connectionEpochRef.current) {
            dispatch({ type: "socket-close", phoneOffline });
          }
        },
        onSynchronizationStart: () => {
          if (epoch === connectionEpochRef.current) {
            dispatch({ type: "resync-start" });
          }
        },
        onSynchronized: () => {
          if (epoch === connectionEpochRef.current) {
            dispatch({ type: "resync-complete" });
          }
        },
        onInventory: (next) => {
          if (epoch !== connectionEpochRef.current) return;
          setInventory(next);
          const nextTabs = next.instances.flatMap((instance) => instance.tabs);
          const nextTabIds = new Set(nextTabs.map((tab) => tab.id));
          setTerminalSessions((currentSessions) => {
            let changed = false;
            const nextSessions = { ...currentSessions };
            for (const existingTabId of Object.keys(nextSessions)) {
              if (!nextTabIds.has(existingTabId)) {
                delete nextSessions[existingTabId];
                terminalSurfacesRef.current.delete(existingTabId);
                changed = true;
              }
            }
            for (const nextTab of nextTabs) {
              const previous = currentSessions[nextTab.id] ?? emptyTerminalSession();
              const inputMode = nextTab.inputMode ?? previous.update.inputMode;
              if (!currentSessions[nextTab.id] || inputMode !== previous.update.inputMode) {
                changed = true;
                nextSessions[nextTab.id] = {
                  ...previous,
                  update: { ...previous.update, inputMode },
                };
              }
            }
            return changed ? nextSessions : currentSessions;
          });
          const pendingMutation = pendingTabMutationRef.current;
          const createdTab = pendingMutation?.kind === "create"
            ? nextTabs.find((candidate) =>
                candidate.instanceId === pendingMutation.instanceId &&
                !pendingMutation.beforeTabIds.has(candidate.id))
            : undefined;
          const closeConfirmed = pendingMutation?.kind === "close" &&
            !nextTabIds.has(pendingMutation.tabId);
          const closeFallback = pendingMutation?.kind === "close"
            ? nextTabs.find((candidate) => candidate.id === pendingMutation.fallbackTabId)
            : undefined;
          const current = selectedTabRef.current;
          const nextId = createdTab?.id ?? closeFallback?.id ?? (current && nextTabs.some((tab) => tab.id === current)
            ? current
            : next.selectedTabId && nextTabs.some((tab) => tab.id === next.selectedTabId)
              ? next.selectedTabId
              : nextTabs[0]?.id);
          selectedTabRef.current = nextId;
          setSelectedTabId(nextId);
          if (nextId) {
            setView((currentView) => currentView === "dashboard" ? "terminal" : currentView);
          } else {
            setView("dashboard");
          }
          if (createdTab || closeConfirmed) {
            clearPendingTabMutation(pendingMutation?.operationId);
          }
        },
        onOutput: (nextOutput) => {
          if (epoch !== connectionEpochRef.current) return;
          applyTerminalOutput(nextOutput);
        },
        onHealth: (rttMs) => {
          if (epoch === connectionEpochRef.current) dispatch({ type: "health", rttMs });
        },
        onMacStale: () => {
          if (epoch === connectionEpochRef.current) dispatch({ type: "resync-start" });
        },
        onMacOffline: () => {
          if (epoch === connectionEpochRef.current) dispatch({ type: "mac-stale" });
        },
        onRotating: () => {
          if (epoch === connectionEpochRef.current) dispatch({ type: "rotation-start" });
        },
        onSessionEnded: (reason) => {
          if (epoch !== connectionEpochRef.current) return;
          void clearControllerSession();
          dispatch({
            type: "ended",
            revoked: reason === "controller-revoked",
          });
        },
        onAck: (_requestId, accepted, detail) => {
          if (epoch !== connectionEpochRef.current) return;
          if (!accepted) {
            dispatch({
              type: "delivery-uncertain",
              detail: detail ?? "The Mac did not accept this request.",
            });
          }
        },
        onProtocolError: (error) => {
          if (epoch === connectionEpochRef.current) {
            console.error("TerminalDB remote protocol error", error.message);
          }
        },
      });
      if (epoch !== connectionEpochRef.current) {
        client.close();
        return;
      }
      clientRef.current?.close();
      clientRef.current = client;
      const paired = await client.connect();
      if (epoch !== connectionEpochRef.current) {
        client.close();
        return;
      }
      setAccessState(paired ? "paired" : "unpaired");
    } catch (error) {
      setAccessState((await loadControllerSession()) ? "paired" : "unpaired");
      dispatch({
        type: "socket-close",
        phoneOffline: navigator.onLine === false,
      });
      console.error(
        "TerminalDB remote connection failed",
        error instanceof Error ? error.message : error,
      );
    }
  }, [applyTerminalOutput, clearPendingTabMutation, forceUnpaired]);

  useEffect(() => {
    if (pairingId) return;
    void connect();
    return () => {
      connectionEpochRef.current += 1;
      clientRef.current?.close();
      clientRef.current = null;
    };
  }, [pairingId, connect]);

  useEffect(() => {
    const onVisible = () => {
      if (document.visibilityState === "visible") {
        clientRef.current?.setViewing(selectedTabRef.current);
        if (!canAcceptTerminalInput(connection)) {
          if (!connection.socketOpen) dispatch({ type: "retry" });
          clientRef.current?.retryNow();
        }
      } else {
        clientRef.current?.setViewing(undefined);
      }
    };
    const onOnline = () => {
      if (!canAcceptTerminalInput(connection)) {
        if (!connection.socketOpen) dispatch({ type: "retry" });
        clientRef.current?.retryNow();
      }
    };
    document.addEventListener("visibilitychange", onVisible);
    window.addEventListener("online", onOnline);
    window.addEventListener("focus", onVisible);
    window.addEventListener("pageshow", onVisible);
    return () => {
      document.removeEventListener("visibilitychange", onVisible);
      window.removeEventListener("online", onOnline);
      window.removeEventListener("focus", onVisible);
      window.removeEventListener("pageshow", onVisible);
    };
  }, [
    connection.lastSyncAt,
    connection.socketOpen,
    connection.state,
    connection.synchronized,
  ]);

  const pair = async () => {
    if (!pairingId || !pairingSecret || pairing) return;
    setPairing(true);
    setPairError(undefined);
    try {
      await redeemPairing({ pairingId, secret: pairingSecret });
      setAccessState("checking");
    } catch (error) {
      setPairError(error instanceof Error ? error.message : "Unable to pair this browser.");
    } finally {
      setPairing(false);
    }
  };

  useEffect(() => {
    if (!pairingId || !pairingSecret || pairingAttemptedRef.current) return;
    pairingAttemptedRef.current = true;
    void pair();
  }, [pairingId, pairingSecret]);

  const openTab = (tab: RemoteTab) => {
    const changed = selectedTabRef.current !== tab.id;
    flushTerminalInput();
    selectedTabRef.current = tab.id;
    setSelectedTabId(tab.id);
    setTerminalSessions((current) => current[tab.id]
      ? current
      : { ...current, [tab.id]: emptyTerminalSession(0, tab.inputMode ?? "secure") });
    clientRef.current?.setViewing(tab.id);
    setView("terminal");
    if (!changed) return;
    const client = clientRef.current;
    if (client && canAcceptTerminalInput(connection)) {
      void client.send("tab.select", { tabId: tab.id }).catch(() => {
        client.requestViewport("tab-select-reconcile");
      });
    } else if (import.meta.env.DEV) {
      const mockWindow = window as Window & { __terminaldbMockTabCommands?: string[] };
      mockWindow.__terminaldbMockTabCommands ??= [];
      mockWindow.__terminaldbMockTabCommands.push(`select:${tab.id}`);
    }
  };

  const createTab = () => {
    const source = selectedTab;
    if (!source || pendingTabMutationRef.current || !canAcceptTerminalInput(connection)) return;
    flushTerminalInput();
    const client = clientRef.current;
    if (!client && import.meta.env.DEV) {
      const id = `tab_mock_${Date.now().toString(36)}`;
      const {
        parentPaneId: _parentPaneId,
        splitDirection: _splitDirection,
        model: _model,
        ...sourceTab
      } = source;
      const created: RemoteTab = {
        ...sourceTab,
        id,
        paneId: id,
        title: "zsh",
        foregroundProcess: "zsh",
        inputMode: "echo",
        busy: false,
        claudeState: "ready",
        updatedAt: new Date().toISOString(),
      };
      setInventory((current) => ({
        ...current,
        selectedTabId: id,
        instances: current.instances.map((instance) =>
          instance.id === source.instanceId
            ? { ...instance, tabs: [...instance.tabs, created] }
            : instance),
      }));
      setTerminalSessions((current) => ({
        ...current,
        [id]: emptyTerminalSession(0, "echo"),
      }));
      selectedTabRef.current = id;
      setSelectedTabId(id);
      const mockWindow = window as Window & { __terminaldbMockTabCommands?: string[] };
      mockWindow.__terminaldbMockTabCommands ??= [];
      mockWindow.__terminaldbMockTabCommands.push(`create:${source.id}`);
      return;
    }
    if (!client) return;

    const operationId = crypto.randomUUID();
    const timer = window.setTimeout(() => {
      if (pendingTabMutationRef.current?.operationId !== operationId) return;
      client.requestViewport("tab-create-timeout");
      clearPendingTabMutation(operationId);
    }, 12_000);
    pendingTabMutationRef.current = {
      operationId,
      kind: "create",
      tabId: source.id,
      instanceId: source.instanceId,
      beforeTabIds: new Set(allTabs.map((candidate) => candidate.id)),
      fallbackTabId: undefined,
      timer,
    };
    setTabMutation({ kind: "create", tabId: source.id });
    void client.send("tab.create", { tabId: source.id }).then(() => {
      client.requestViewport("tab-created");
    }).catch((error: unknown) => {
      if (pendingTabMutationRef.current?.operationId !== operationId) return;
      clearPendingTabMutation(operationId);
      dispatch({
        type: "delivery-uncertain",
        detail: error instanceof Error ? error.message : "The new tab could not be confirmed.",
      });
    });
  };

  const closeTab = (target: RemoteTab) => {
    if (
      target.busy || target.parentPaneId || pendingTabMutationRef.current ||
      !canAcceptTerminalInput(connection)
    ) return;
    flushTerminalInput();
    const client = clientRef.current;
    const instanceTabs = inventory.instances
      .find((instance) => instance.id === target.instanceId)?.tabs ?? [];
    const instanceIndex = instanceTabs.findIndex((candidate) => candidate.id === target.id);
    const fallbackTab = instanceTabs[instanceIndex + 1] ?? instanceTabs[instanceIndex - 1] ??
      allTabs.find((candidate) => candidate.id !== target.id);
    if (!client && import.meta.env.DEV) {
      const remaining = allTabs.filter((candidate) => candidate.id !== target.id);
      const nextSelected = target.id === selectedTabRef.current
        ? remaining.find((candidate) => candidate.id === fallbackTab?.id)
        : remaining.find((candidate) => candidate.id === selectedTabRef.current);
      setInventory((current) => {
        const { selectedTabId: _selectedTabId, ...rest } = current;
        const next = {
          ...rest,
          instances: current.instances.map((instance) => ({
            ...instance,
            tabs: instance.tabs.filter((candidate) => candidate.id !== target.id),
          })),
        };
        return nextSelected ? { ...next, selectedTabId: nextSelected.id } : next;
      });
      setTerminalSessions((current) => {
        const next = { ...current };
        delete next[target.id];
        return next;
      });
      selectedTabRef.current = nextSelected?.id;
      setSelectedTabId(nextSelected?.id);
      if (!nextSelected) setView("dashboard");
      const mockWindow = window as Window & { __terminaldbMockTabCommands?: string[] };
      mockWindow.__terminaldbMockTabCommands ??= [];
      mockWindow.__terminaldbMockTabCommands.push(`close:${target.id}`);
      return;
    }
    if (!client) return;

    const operationId = crypto.randomUUID();
    const timer = window.setTimeout(() => {
      if (pendingTabMutationRef.current?.operationId !== operationId) return;
      client.requestViewport("tab-close-timeout");
      clearPendingTabMutation(operationId);
    }, 12_000);
    pendingTabMutationRef.current = {
      operationId,
      kind: "close",
      tabId: target.id,
      instanceId: target.instanceId,
      beforeTabIds: new Set(allTabs.map((candidate) => candidate.id)),
      fallbackTabId: fallbackTab?.id,
      timer,
    };
    setTabMutation({ kind: "close", tabId: target.id });
    void client.send("tab.close", { tabId: target.id }).then(() => {
      client.requestViewport("tab-closed");
    }).catch((error: unknown) => {
      if (pendingTabMutationRef.current?.operationId !== operationId) return;
      clearPendingTabMutation(operationId);
      dispatch({
        type: "delivery-uncertain",
        detail: error instanceof Error ? error.message : "The tab closure could not be confirmed.",
      });
    });
  };

  const deliverTerminalInput = (tabId: string, input: string) => {
    const acceptsInput = canAcceptTerminalInput(connection);
    if (!input || !acceptsInput) return;
    const client = clientRef.current;
    const deliver = async () => {
      if (client) {
        await client.send("pty.input", { tabId, input });
        return;
      }
      const mockWindow = window as Window & {
        __terminaldbMockInputs?: string[];
        __terminaldbMockEchoDelayMs?: number;
        __terminaldbMockAckDelayMs?: number;
      };
      if (import.meta.env.DEV) {
        mockWindow.__terminaldbMockInputs ??= [];
        mockWindow.__terminaldbMockInputs.push(input);
      }
      const mockEcho = input.replaceAll("\r", "\r\n");
      const applyMockEcho = () => {
        terminalUpdateIdRef.current += 1;
        setTerminalSessions((current) => {
          const previous = current[tabId] ?? emptyTerminalSession();
          return {
            ...current,
            [tabId]: {
              ...previous,
              update: {
                ...previous.update,
                id: terminalUpdateIdRef.current,
                text: mockEcho,
                viewport: false,
                inputMode: previous.update.inputMode,
              },
            },
          };
        });
      };
      const delay = import.meta.env.DEV
        ? Math.max(0, mockWindow.__terminaldbMockEchoDelayMs ?? 0)
        : 0;
      if (delay > 0) window.setTimeout(applyMockEcho, delay);
      else applyMockEcho();
      const acknowledgementDelay = import.meta.env.DEV
        ? Math.max(0, mockWindow.__terminaldbMockAckDelayMs ?? 0)
        : 0;
      if (acknowledgementDelay > 0) {
        await new Promise<void>((resolve) => {
          window.setTimeout(resolve, acknowledgementDelay);
        });
      }
    };
    void inputDeliveryQueueRef.current?.enqueue(tabId, deliver).then((result) => {
      if (result === "delivered") {
        terminalSurfacesRef.current.get(tabId)?.confirmOptimisticInput(
          /[\r\n]/u.test(input),
        );
      }
    }).catch((error: unknown) => {
      terminalSurfacesRef.current.get(tabId)?.rollbackOptimisticInput();
      dispatch({
        type: "delivery-uncertain",
        detail: error instanceof Error ? error.message : "The input may not have reached the Mac.",
      });
    });
  };

  const flushTerminalInput = () => {
    if (terminalInputTimerRef.current) {
      window.clearTimeout(terminalInputTimerRef.current);
      terminalInputTimerRef.current = undefined;
    }
    const pending = pendingTerminalInputRef.current;
    pendingTerminalInputRef.current = undefined;
    if (pending) deliverTerminalInput(pending.tabId, pending.data);
  };

  const sendTerminalInput = (input: string) => {
    const tabId = selectedTabRef.current;
    const acceptsInput = canAcceptTerminalInput(connection);
    if (!tabId || !input || !acceptsInput) return;
    const pending = pendingTerminalInputRef.current;
    if (pending && pending.tabId !== tabId) flushTerminalInput();
    const current = pendingTerminalInputRef.current;
    pendingTerminalInputRef.current = {
      tabId,
      data: `${current?.data ?? ""}${input}`,
    };
    const flushImmediately = /[\r\n\u0003\u001b]/u.test(input);
    if (flushImmediately) {
      flushTerminalInput();
      return;
    }
    if (terminalInputTimerRef.current) {
      window.clearTimeout(terminalInputTimerRef.current);
    }
    terminalInputTimerRef.current = window.setTimeout(
      flushTerminalInput,
      TERMINAL_INPUT_BATCH_DELAY_MS,
    );
  };

  const setTabFollowOutput = (tabId: string, followOutput: boolean) => {
    setTerminalSessions((current) => {
      const previous = current[tabId] ?? emptyTerminalSession();
      if (previous.followOutput === followOutput) return current;
      return { ...current, [tabId]: { ...previous, followOutput } };
    });
  };

  const setTabGeometry = (tabId: string, columns: number, rows: number) => {
    const client = clientRef.current;
    if (client) {
      client.setViewportGeometry(tabId, columns, rows);
    } else if (import.meta.env.DEV && tabId === selectedTabRef.current) {
      const mockWindow = window as Window & {
        __terminaldbMockResizeCommands?: Array<{
          tabId: string;
          columns: number;
          rows: number;
        }>;
      };
      const previous = mockWindow.__terminaldbMockResizeCommands?.at(-1);
      if (
        previous?.tabId !== tabId ||
        previous.columns !== columns ||
        previous.rows !== rows
      ) {
        mockWindow.__terminaldbMockResizeCommands ??= [];
        mockWindow.__terminaldbMockResizeCommands.push({ tabId, columns, rows });
      }
    }
    setTerminalSessions((current) => {
      const previous = current[tabId] ?? emptyTerminalSession();
      if (
        previous.localColumns === columns &&
        previous.localRows === rows
      ) return current;
      return {
        ...current,
        [tabId]: { ...previous, localColumns: columns, localRows: rows },
      };
    });
  };

  const copyTerminal = async (tabId: string) => {
    const surface = terminalSurfacesRef.current.get(tabId);
    const text = surface?.getSelection() || surface?.getViewportText() || "";
    if (text) await navigator.clipboard.writeText(text);
  };

  const quickKey = (key: string) => {
    const values: Record<string, string> = {
      Esc: "\u001b",
      Ctrl: "",
      Tab: "\t",
      "↑": "\u001b[A",
      "↓": "\u001b[B",
      "←": "\u001b[D",
      "→": "\u001b[C",
      "^C": "\u0003",
    };
    const input = values[key];
    if (!input) return;
    sendTerminalInput(input);
  };

  const switchAccount = async (account: ClaudeAccount) => {
    if (!selectedTab || selectedTab.busy) return;
    try {
      await clientRef.current?.send("account.switch", {
        tabId: selectedTab.id,
        accountId: account.id,
      });
    } catch (error) {
      dispatch({
        type: "delivery-uncertain",
        detail: error instanceof Error
          ? error.message
          : "The account change could not be confirmed.",
      });
    }
  };

  const refreshUsage = async () => {
    if (!clientRef.current || usageRefreshing) return;
    setUsageRefreshing(true);
    try {
      await clientRef.current.send("usage.refresh", {});
    } catch (error) {
      dispatch({
        type: "delivery-uncertain",
        detail: error instanceof Error ? error.message : "Usage refresh could not be confirmed.",
      });
    } finally {
      window.setTimeout(() => setUsageRefreshing(false), 1_000);
    }
  };

  if (pairingId) {
    return (
      <PairingView
        pairingId={pairingId}
        onPair={() => void pair()}
        error={pairError}
        pairing={pairing}
      />
    );
  }

  if (accessState !== "paired") {
    return <UnpairedView checking={accessState === "checking"} />;
  }

  const terminalWorkspace = Boolean(
    selectedTab && ["terminal", "accounts", "devices", "diagnostics"].includes(view),
  );

  return (
    <div className={`remote-shell ${terminalWorkspace ? "terminal-active" : ""}`}>
      {!terminalWorkspace ? (
        <header className="app-header">
          <button className="brand-button" onClick={() => setView("dashboard")} aria-label="Open remote ledger">
            <AppMark />
            <span><b>TerminalDB</b><small>REMOTE</small></span>
          </button>
          <ConnectionPill state={connection} onClick={() => setView("diagnostics")} />
        </header>
      ) : null}

      {view === "dashboard" ? <Dashboard inventory={inventory} onOpenTab={openTab} /> : null}
      {terminalWorkspace && selectedTab ? (
        <TerminalView
          tab={selectedTab}
          tabs={allTabs}
          accounts={inventory.accounts}
          terminalSessions={terminalSessions}
          state={connection}
          onSelectTab={openTab}
          onCreateTab={createTab}
          onCloseTab={closeTab}
          tabMutation={tabMutation}
          onInput={sendTerminalInput}
          onQuickKey={quickKey}
          onBack={() => setView("dashboard")}
          onAccounts={() => setView("accounts")}
          onDevices={() => setView("devices")}
          onDiagnostics={() => setView("diagnostics")}
          onCopy={(tabId) => void copyTerminal(tabId)}
          onFollowOutputChange={setTabFollowOutput}
          onGeometryChange={setTabGeometry}
          onAuthoritativeRefreshNeeded={() => {
            clientRef.current?.requestViewport("optimistic-input-reconcile");
          }}
          onSurface={(tabId, surface) => {
            if (surface) terminalSurfacesRef.current.set(tabId, surface);
            else terminalSurfacesRef.current.delete(tabId);
          }}
        />
      ) : null}
      {terminalWorkspace && view !== "terminal" ? (
        <aside className="terminal-sheet" aria-label="Terminal settings">
          <button className="sheet-close" onClick={() => setView("terminal")} aria-label="Close panel">×</button>
          {view === "accounts" ? (
            <AccountsView
              accounts={inventory.accounts}
              selectedTab={selectedTab}
              onSwitch={(account) => void switchAccount(account)}
              onRefresh={() => void refreshUsage()}
              refreshing={usageRefreshing}
              canControl={
                connection.state === "live" || connection.state === "slow"
              }
            />
          ) : null}
          {view === "devices" ? (
            <DevicesView
              state={connection}
              onRevoke={() => {
                void (async () => {
                  try {
                    await clientRef.current?.revokeThisController();
                    clientRef.current?.close();
                    await clearControllerSession();
                    dispatch({ type: "ended", revoked: true });
                  } catch (error) {
                    dispatch({
                      type: "delivery-uncertain",
                      detail: error instanceof Error ? error.message : "Revocation could not be confirmed.",
                    });
                  }
                })();
              }}
              onEndSession={() => {
                void clientRef.current
                  ?.send("session.end", {})
                  .then(async () => {
                    clientRef.current?.close();
                    await clearControllerSession();
                    dispatch({ type: "ended", revoked: false });
                  })
                  .catch((error: unknown) => {
                    dispatch({
                      type: "delivery-uncertain",
                      detail: error instanceof Error ? error.message : "Session end could not be confirmed.",
                    });
                  });
              }}
            />
          ) : null}
          {view === "diagnostics" ? (
            <DiagnosticsView
              model={connection}
              region={remoteRegion}
              controller={controllerDeviceName()}
            />
          ) : null}
        </aside>
      ) : null}
      {view === "lab" ? <LabView model={connection} dispatch={dispatch} /> : null}

      {!terminalWorkspace ? <nav className="bottom-nav" aria-label="Remote sections">
        {[
          ["dashboard", "▦", "Sessions"],
          ["terminal", ">_", "Terminal"],
          ["accounts", "●", "Accounts"],
          ["devices", "▯", "Devices"],
          ["lab", "⌁", "Lab"],
        ].map(([id, icon, label]) => (
          <button
            key={id}
            className={view === id ? "active" : ""}
            onClick={() => setView(id as View)}
            disabled={id === "terminal" && !selectedTab}
          >
            <span>{icon}</span>
            {label}
          </button>
        ))}
      </nav> : null}
    </div>
  );
}
