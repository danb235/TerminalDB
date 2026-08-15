import {
  PROTOCOL_VERSION,
  type ClaudeAccount,
  type ConnectionState,
  type InventoryPayload,
  type PTYOutputPayload,
  type RemotePublicConfiguration,
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
import QRCode from "qrcode";

import {
  CLAUDE_USAGE_LABELS,
  stableClaudeAccounts,
  stableClaudeUsage,
} from "./account-list";
import { clearControllerSession, loadControllerSession } from "./identity";
import {
  accountAccessToken,
  beginAccountPasswordReset,
  beginAccountPasswordSignIn,
  beginAccountTotpEnrollment,
  changeAccountPassword,
  clearAccountCredentials,
  clearPendingAccountBootstrap,
  completeAccountSignIn,
  completeAccountTotpEnrollment,
  completeAccountTotpSignIn,
  hasRecentAccountAuthentication,
  pendingAccountBootstrap,
  savePendingAccountBootstrap,
  signOutAccount,
  type AccountTotpEnrollment,
  type AccountTotpSignIn,
} from "./account-auth";
import { accounts as mockAccounts, mockInventory, terminalFixture } from "./mock-data";
import { AcknowledgedInputQueue } from "./ordered-input";
import type { SequencedInputBatch } from "./ordered-input";
import {
  controllerDeviceName,
  cancelAccountBootstrap,
  completeAccountBootstrap,
  deleteTerminalDBAccount,
  listAccountDevices,
  loadPublicConfiguration,
  openAccountSession,
  recordAccountPasswordChanged,
  redeemPairing,
  RemoteClient,
  type AccountDeviceSummary,
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

type View = "dashboard" | "terminal" | "accounts" | "controls" | "diagnostics" | "lab";
type AccountBootstrapSupport = "checking" | "supported" | "upgrade-required";
type InventoryPhase = "loading" | "ready";
export type DashboardSessionPresentation = "loading" | "empty" | "offline" | "sessions";

export function dashboardSessionPresentation(
  phase: InventoryPhase,
  tabCount: number,
  connectionState: ConnectionState,
): DashboardSessionPresentation {
  if (tabCount > 0) return "sessions";
  if ([
    "phone-offline",
    "mac-offline",
    "remote-ended",
    "revoked",
    "update-required",
  ].includes(connectionState)) return "offline";
  if (["connecting", "reconnecting", "resyncing", "rotating"].includes(connectionState)) {
    return "loading";
  }
  return phase === "loading" ? "loading" : "empty";
}

export function shouldOpenInitialTerminal(
  accessMode: "pairing" | "account",
  currentView: View,
): boolean {
  return accessMode === "pairing" && currentView === "dashboard";
}

export function accountBootstrapSupport(
  inventory: Pick<InventoryPayload, "capabilities" | "instances">,
): AccountBootstrapSupport {
  if (inventory.capabilities?.includes("account-bootstrap-v1")) return "supported";
  if (inventory.capabilities !== undefined || inventory.instances.length > 0) {
    return "upgrade-required";
  }
  return "checking";
}

const TERMINAL_INPUT_BATCH_DELAY_MS = 40;

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

export interface DashboardDeviceRow {
  readonly id: string;
  readonly name: string;
  readonly state: "online" | "connecting" | "offline";
  readonly current: boolean;
  readonly instances: InventoryPayload["instances"];
  readonly summary: AccountDeviceSummary | undefined;
}

export function dashboardDeviceRows(
  inventory: InventoryPayload,
  presentation: DashboardSessionPresentation,
  accountDevices: readonly AccountDeviceSummary[],
  activeSessionId?: string,
): readonly DashboardDeviceRow[] {
  const instancesByHost = new Map<string, InventoryPayload["instances"]>();
  for (const instance of inventory.instances) {
    instancesByHost.set(instance.host, [...(instancesByHost.get(instance.host) ?? []), instance]);
  }
  const sortedAccountDevices = [...accountDevices].sort((left, right) =>
    left.deviceName.localeCompare(right.deviceName));
  const currentAccountDevice = sortedAccountDevices.find((device) =>
    device.sessionId === activeSessionId);
  const currentHost = currentAccountDevice?.deviceName ?? inventory.instances[0]?.host ?? "This Mac";
  const accountDeviceRows: DashboardDeviceRow[] = sortedAccountDevices.map((device) => ({
    id: device.deviceId,
    name: device.deviceName,
    state: device.sessionId === activeSessionId
      ? presentation === "offline" ? "offline" as const : "online" as const
      : device.state,
    current: device.sessionId === activeSessionId,
    instances: device.sessionId === activeSessionId ? inventory.instances : [],
    summary: device,
  }));
  if (activeSessionId && !currentAccountDevice) {
    accountDeviceRows.unshift({
      id: activeSessionId,
      name: currentHost,
      state: presentation === "offline" ? "offline" : "online",
      current: true,
      instances: inventory.instances,
      summary: undefined,
    });
  }
  const localDeviceRows: DashboardDeviceRow[] = [...instancesByHost.entries()]
    .map(([host, instances]) => ({
      id: host,
      name: host,
      state: presentation === "offline" ? "offline" as const : "online" as const,
      current: true,
      instances,
      summary: undefined,
    }));
  return accountDeviceRows.length > 0 ? accountDeviceRows : localDeviceRows;
}

function Dashboard({
  inventory,
  presentation,
  accountDevices,
  activeSessionId,
  devicesLoading,
  devicesError,
  switchingDeviceId,
  onOpenTab,
  onOpenDevice,
}: {
  readonly inventory: InventoryPayload;
  readonly presentation: DashboardSessionPresentation;
  readonly accountDevices: readonly AccountDeviceSummary[];
  readonly activeSessionId?: string | undefined;
  readonly devicesLoading: boolean;
  readonly devicesError?: string | undefined;
  readonly switchingDeviceId?: string | undefined;
  readonly onOpenTab: (tab: RemoteTab) => void;
  readonly onOpenDevice: (device: AccountDeviceSummary) => void;
}) {
  const allTabs = inventory.instances.flatMap((instance) => instance.tabs);
  const deviceRows = dashboardDeviceRows(
    inventory,
    presentation,
    accountDevices,
    activeSessionId,
  );
  return (
    <main className="view dashboard-view">
      <section className="hero-status">
        <span className="eyebrow">TERMINALDB REMOTE</span>
        <div className="hero-line">
          <h1>Devices &amp; sessions</h1>
          <span>{deviceRows.length} {deviceRows.length === 1 ? "device" : "devices"} · {allTabs.length} {allTabs.length === 1 ? "tab" : "tabs"}</span>
        </div>
        <p>Every available Mac, TerminalDB window, and terminal tab in one place.</p>
      </section>

      {devicesLoading ? (
        <p className="device-refresh-status" role="status">Refreshing your devices…</p>
      ) : null}
      {devicesError ? <p className="device-refresh-error" role="alert">{devicesError}</p> : null}

      {deviceRows.length === 0 && presentation === "empty" ? (
        <section className="session-state-card" aria-live="polite">
          <div className="session-state-icon" aria-hidden="true">&gt;_</div>
          <span className="session-state-kicker">NO DEVICES AVAILABLE</span>
          <h2>Open TerminalDB on your Mac</h2>
          <p>Your enrolled Macs and their open terminal tabs will appear here automatically—no new link or sign-in needed.</p>
        </section>
      ) : null}

      {deviceRows.length === 0 && presentation === "offline" ? (
        <section className="session-state-card is-offline" aria-live="polite">
          <div className="session-state-icon" aria-hidden="true">···</div>
          <span className="session-state-kicker">WAITING FOR TERMINALDB</span>
          <h2>Your devices are offline</h2>
          <p>You’re still signed in. Open TerminalDB on any enrolled Mac and its terminal sessions will appear here automatically.</p>
        </section>
      ) : null}

      {deviceRows.length > 0 ? <section>
        <div className="section-title">
          <span>YOUR DEVICES</span>
          <small>Updates automatically</small>
        </div>
        <div className="device-session-list">
          {deviceRows.map((device) => {
            const tabCount = device.instances.reduce((count, instance) => count + instance.tabs.length, 0);
            const canOpen = Boolean(device.summary?.sessionId) && !device.current && device.state === "online";
            return <article className={`home-device ${device.current ? "active" : ""}`} key={device.id}>
              <header className="home-device-header">
                <div>
                  <span className={`device-state device-state-${device.state}`} aria-hidden="true" />
                  <div>
                    <strong>{device.name}</strong>
                    <small>{device.current
                      ? `${tabCount} ${tabCount === 1 ? "tab" : "tabs"} available now`
                      : device.state === "online"
                        ? "Online · select to view its sessions"
                        : device.state === "connecting"
                          ? "Connecting securely…"
                          : `Offline${device.summary ? ` · ${accountDeviceActivityLabel(device.summary.lastSeenAt)}` : ""}`}</small>
                  </div>
                </div>
                {device.current ? <span className="current-device-label">CURRENT</span> : null}
                {canOpen && device.summary ? (
                  <button
                    disabled={Boolean(switchingDeviceId)}
                    onClick={() => onOpenDevice(device.summary!)}
                  >
                    {switchingDeviceId === device.id ? "Opening…" : "View sessions"}
                  </button>
                ) : null}
                {!device.current && !canOpen ? <span>{device.state === "connecting" ? "CONNECTING" : "OFFLINE"}</span> : null}
              </header>
              {device.current && device.instances.length === 0 ? (
                <div className="home-device-empty">
                  <strong>No terminal windows are open</strong>
                  <span>Open a TerminalDB window on this Mac and its tabs will appear here.</span>
                </div>
              ) : null}
              {device.instances.map((instance) => (
                <section className="instance" key={instance.id}>
                  <header>
                    <div>
                      <strong>{instance.name}</strong>
                      <small>{instance.tabs.length} {instance.tabs.length === 1 ? "tab" : "tabs"}</small>
                    </div>
                  </header>
                  <div className="session-list">
                    {instance.tabs.map((tab) => (
                      <SessionCard key={tab.id} tab={tab} onOpen={() => onOpenTab(tab)} />
                    ))}
                  </div>
                </section>
              ))}
            </article>;
          })}
        </div>
      </section> : null}
    </main>
  );
}

function SessionLoadingView({
  connectionState,
}: {
  readonly connectionState: ConnectionState;
}) {
  const status = connectionState === "resyncing" || connectionState === "rotating"
    ? "Syncing your latest sessions…"
    : connectionState === "reconnecting"
      ? "Reconnecting securely…"
      : "Connecting securely…";
  return (
    <main className="session-loading-view" aria-live="polite" aria-busy="true">
      <div className="session-loading-content">
        <div className="session-loading-brand">
          <AppMark />
          <strong>TerminalDB</strong>
        </div>
        <div className="session-loading-spinner" aria-hidden="true"><span /></div>
        <h1>Connecting to your terminals</h1>
        <p>Checking your connected Macs and loading their open windows and tabs.</p>
        <div className="session-loading-track" aria-hidden="true"><span /></div>
        <strong className="session-loading-status">{status}</strong>
      </div>
    </main>
  );
}

export function accountDeviceActivityLabel(
  lastSeenAt: number,
  now = Date.now(),
): string {
  if (!Number.isFinite(lastSeenAt) || lastSeenAt <= 0) return "Never online";
  const seconds = Math.max(0, Math.floor(now / 1_000) - lastSeenAt);
  if (seconds < 60) return "Last seen just now";
  if (seconds < 60 * 60) return `Last seen ${Math.floor(seconds / 60)}m ago`;
  if (seconds < 24 * 60 * 60) return `Last seen ${Math.floor(seconds / (60 * 60))}h ago`;
  return `Last seen ${Math.floor(seconds / (24 * 60 * 60))}d ago`;
}

function AccountSignIn({
  configuration,
  onComplete,
  onCancel,
  onRecover,
}: {
  readonly configuration: NonNullable<RemotePublicConfiguration["accountAuth"]>;
  readonly onComplete: (accessToken: string) => void;
  readonly onCancel: () => void;
  readonly onRecover?: () => void;
}) {
  const [username, setUsername] = useState("");
  const [password, setPassword] = useState("");
  const [authenticatorCode, setAuthenticatorCode] = useState("");
  const [signIn, setSignIn] = useState<AccountTotpSignIn>();
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string>();

  const submitPassword = async () => {
    setBusy(true);
    setError(undefined);
    try {
      const challenge = await beginAccountPasswordSignIn({
        configuration,
        username,
        password,
      });
      setUsername(challenge.username);
      setPassword("");
      setSignIn(challenge);
    } catch (signInError) {
      setError(signInError instanceof Error ? signInError.message : "Sign-in could not start.");
    } finally {
      setBusy(false);
    }
  };

  const submitAuthenticator = async () => {
    if (!signIn) return;
    setBusy(true);
    setError(undefined);
    try {
      const token = await completeAccountTotpSignIn({
        configuration,
        signIn,
        code: authenticatorCode,
      });
      setAuthenticatorCode("");
      onComplete(token);
    } catch (signInError) {
      setError(signInError instanceof Error ? signInError.message : "The code could not be verified.");
      setBusy(false);
    }
  };

  if (signIn) {
    return (
      <section className="account-access account-signup account-enrollment account-signin">
        <span>PASSWORD ACCEPTED · AUTHENTICATOR REQUIRED</span>
        <h2>Enter your authenticator code</h2>
        <p>Enter the current six-digit code for <strong>{signIn.username}</strong>.</p>
        <form onSubmit={(event) => {
          event.preventDefault();
          void submitAuthenticator();
        }}>
          <label htmlFor="account-signin-code">Six-digit code</label>
          <input
            id="account-signin-code"
            autoComplete="one-time-code"
            autoFocus
            disabled={busy}
            inputMode="numeric"
            maxLength={6}
            pattern="[0-9]{6}"
            required
            value={authenticatorCode}
            onChange={(event) => setAuthenticatorCode(event.target.value.replace(/\D/gu, ""))}
          />
          <small>Codes change every 30 seconds. If one expires, enter the next code.</small>
          <button disabled={busy} type="submit">
            {busy ? "Verifying…" : "Sign in"}
          </button>
        </form>
        <button
          className="text-button"
          disabled={busy}
          onClick={() => {
            setSignIn(undefined);
            setAuthenticatorCode("");
            setError(undefined);
          }}
        >
          Back
        </button>
        <button className="text-button" disabled={busy} onClick={onCancel}>Cancel</button>
        {error ? <small role="alert">{error}</small> : null}
      </section>
    );
  }

  return (
    <section className="account-access account-signup account-enrollment account-signin">
      <span>TERMINALDB ACCOUNT</span>
      <h2>Sign in to TerminalDB</h2>
      <p>Your password and authenticator code go directly from this browser to AWS Cognito. TerminalDB’s backend never receives them.</p>
      <form onSubmit={(event) => {
        event.preventDefault();
        void submitPassword();
      }}>
        <label htmlFor="account-signin-username">Username</label>
        <input
          id="account-signin-username"
          autoCapitalize="none"
          autoComplete="username"
          autoCorrect="off"
          autoFocus
          disabled={busy}
          required
          value={username}
          onChange={(event) => setUsername(event.target.value)}
        />
        <label htmlFor="account-signin-password">Password</label>
        <input
          id="account-signin-password"
          autoComplete="current-password"
          disabled={busy}
          required
          type="password"
          value={password}
          onChange={(event) => setPassword(event.target.value)}
        />
        <button disabled={busy} type="submit">
          {busy ? "Checking…" : "Continue"}
        </button>
      </form>
      <button className="text-button" disabled={busy} onClick={onCancel}>Cancel</button>
      {error ? (
        <div className="account-signin-recovery" role="alert">
          <strong>{error}</strong>
          {onRecover ? (
            <button className="text-button" disabled={busy} onClick={onRecover}>
              Reset password from an enrolled Mac
            </button>
          ) : null}
          <small>New here? Open TerminalDB on your Mac, choose Remote Control, then Create Account.</small>
        </div>
      ) : null}
    </section>
  );
}

function AccountPasswordReset({
  configuration,
  resetToken,
  onComplete,
  onCancel,
}: {
  readonly configuration: NonNullable<RemotePublicConfiguration["accountAuth"]>;
  readonly resetToken: string;
  readonly onComplete: (accessToken: string) => void;
  readonly onCancel: () => void;
}) {
  const [newPassword, setNewPassword] = useState("");
  const [confirmation, setConfirmation] = useState("");
  const [resetSignIn, setResetSignIn] = useState<AccountTotpSignIn>();
  const [authenticatorCode, setAuthenticatorCode] = useState("");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string>();

  const submitPassword = async () => {
    if (newPassword !== confirmation) {
      setError("The new passwords do not match.");
      return;
    }
    setBusy(true);
    setError(undefined);
    try {
      const challenge = await beginAccountPasswordReset({
        configuration,
        resetToken,
        newPassword,
      });
      setNewPassword("");
      setConfirmation("");
      setResetSignIn(challenge);
    } catch (resetError) {
      setError(resetError instanceof Error ? resetError.message : "Password reset could not start.");
    } finally {
      setBusy(false);
    }
  };

  const submitAuthenticator = async () => {
    if (!resetSignIn) return;
    setBusy(true);
    setError(undefined);
    try {
      const token = await completeAccountTotpSignIn({
        configuration,
        signIn: resetSignIn,
        code: authenticatorCode,
      });
      onComplete(token);
    } catch (resetError) {
      setError(resetError instanceof Error ? resetError.message : "The code could not be verified.");
      setBusy(false);
    }
  };

  return (
    <section className="account-access account-signup account-enrollment account-signin account-password-reset">
      <span>APPROVED BY YOUR MAC</span>
      <h2>{resetSignIn ? "Confirm with your authenticator" : "Choose a new password"}</h2>
      <p>{resetSignIn
        ? `Enter the current six-digit code for ${resetSignIn.username}.`
        : "This one-time approval came from an enrolled TerminalDB Mac. Other browsers will be signed out."}</p>
      {resetSignIn ? (
        <form onSubmit={(event) => { event.preventDefault(); void submitAuthenticator(); }}>
          <label htmlFor="account-reset-code">Six-digit code</label>
          <input
            id="account-reset-code"
            autoComplete="one-time-code"
            autoFocus
            disabled={busy}
            inputMode="numeric"
            maxLength={6}
            pattern="[0-9]{6}"
            required
            value={authenticatorCode}
            onChange={(event) => setAuthenticatorCode(event.target.value.replace(/\D/gu, ""))}
          />
          <button disabled={busy} type="submit">{busy ? "Verifying…" : "Finish password reset"}</button>
        </form>
      ) : (
        <form onSubmit={(event) => { event.preventDefault(); void submitPassword(); }}>
          <label htmlFor="account-reset-password">New password</label>
          <input
            id="account-reset-password"
            autoComplete="new-password"
            autoFocus
            disabled={busy}
            minLength={12}
            required
            type="password"
            value={newPassword}
            onChange={(event) => setNewPassword(event.target.value)}
          />
          <small>At least 12 characters with upper and lowercase letters, a number, and a symbol.</small>
          <label htmlFor="account-reset-password-confirmation">Confirm new password</label>
          <input
            id="account-reset-password-confirmation"
            autoComplete="new-password"
            disabled={busy}
            minLength={12}
            required
            type="password"
            value={confirmation}
            onChange={(event) => setConfirmation(event.target.value)}
          />
          <button disabled={busy} type="submit">{busy ? "Resetting…" : "Continue to authenticator"}</button>
        </form>
      )}
      <button className="text-button" disabled={busy} onClick={onCancel}>Cancel</button>
      {error ? <small role="alert">{error}</small> : null}
    </section>
  );
}

function AccountEnrollment({
  configuration,
  bootstrapToken,
  onComplete,
  onExistingAccount,
  onCancel,
}: {
  readonly configuration: NonNullable<RemotePublicConfiguration["accountAuth"]>;
  readonly bootstrapToken: string;
  readonly onComplete: (accessToken: string) => void;
  readonly onExistingAccount: () => void;
  readonly onCancel: () => Promise<void>;
}) {
  const [stage, setStage] = useState<"intro" | "credentials" | "totp">("intro");
  const [username, setUsername] = useState("");
  const [password, setPassword] = useState("");
  const [passwordConfirmation, setPasswordConfirmation] = useState("");
  const [enrollment, setEnrollment] = useState<AccountTotpEnrollment>();
  const [authenticatorCode, setAuthenticatorCode] = useState("");
  const [qrCode, setQrCode] = useState<string>();
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string>();
  const [copyStatus, setCopyStatus] = useState<string>();

  useEffect(() => {
    if (!enrollment) {
      setQrCode(undefined);
      return;
    }
    let canceled = false;
    const label = encodeURIComponent(`TerminalDB:${enrollment.username}`);
    const issuer = encodeURIComponent("TerminalDB");
    const uri = `otpauth://totp/${label}?secret=${enrollment.secret}&issuer=${issuer}&algorithm=SHA1&digits=6&period=30`;
    void QRCode.toDataURL(uri, {
      width: 224,
      margin: 2,
      errorCorrectionLevel: "M",
      color: { dark: "#101013", light: "#ffffff" },
    }).then((dataUrl) => {
      if (!canceled) setQrCode(dataUrl);
    }).catch(() => {
      if (!canceled) setError("The QR code could not be drawn. Use the setup key below.");
    });
    return () => {
      canceled = true;
    };
  }, [enrollment]);

  const submitCredentials = async () => {
    if (password !== passwordConfirmation) {
      setError("The passwords do not match.");
      return;
    }
    setBusy(true);
    setError(undefined);
    try {
      const nextEnrollment = await beginAccountTotpEnrollment({
        configuration,
        username,
        password,
        bootstrapToken,
      });
      setEnrollment(nextEnrollment);
      setUsername(nextEnrollment.username);
      setPassword("");
      setPasswordConfirmation("");
      setStage("totp");
    } catch (setupError) {
      setError(setupError instanceof Error ? setupError.message : "Account setup could not start.");
    } finally {
      setBusy(false);
    }
  };

  const verifyAuthenticator = async () => {
    if (!enrollment) return;
    setBusy(true);
    setError(undefined);
    try {
      const accessToken = await completeAccountTotpEnrollment({
        configuration,
        enrollment,
        code: authenticatorCode,
      });
      setAuthenticatorCode("");
      onComplete(accessToken);
    } catch (verificationError) {
      setError(verificationError instanceof Error
        ? verificationError.message
        : "The authenticator code could not be verified.");
      setBusy(false);
    }
  };

  const copySetupKey = async () => {
    if (!enrollment) return;
    setCopyStatus(undefined);
    const fallbackCopy = () => {
      const field = document.createElement("textarea");
      field.value = enrollment.secret;
      field.setAttribute("readonly", "");
      field.style.position = "fixed";
      field.style.opacity = "0";
      document.body.append(field);
      field.select();
      const copied = document.execCommand("copy");
      field.remove();
      return copied;
    };
    try {
      if (!navigator.clipboard?.writeText) {
        if (!fallbackCopy()) throw new Error("Clipboard unavailable");
      } else {
        await Promise.race([
          navigator.clipboard.writeText(enrollment.secret),
          new Promise<never>((_resolve, reject) => {
            window.setTimeout(() => reject(new Error("Clipboard timed out")), 750);
          }),
        ]).catch((clipboardError: unknown) => {
          if (!fallbackCopy()) throw clipboardError;
        });
      }
      setCopyStatus("Setup key copied.");
    } catch {
      setCopyStatus("Copy was blocked. Select the setup key and copy it manually.");
    }
  };

  const cancel = async () => {
    setBusy(true);
    setError(undefined);
    try {
      await onCancel();
    } catch (cancelError) {
      setError(cancelError instanceof Error ? cancelError.message : "Account setup could not be canceled.");
      setBusy(false);
    }
  };

  if (stage === "intro") {
    return (
      <section className="account-access account-signup">
        <span>MAC APPROVED · NO EMAIL REQUIRED</span>
        <h2>Create your TerminalDB account</h2>
        <p>This one-time approval connects the Mac that opened this page. Your password and authenticator setup go directly from this browser to AWS Cognito.</p>
        <div className="account-security-notice">
          <strong>Authenticator app required</strong>
          <p>You can scan a QR code or copy the setup key into your authenticator app. Both options are shown together on the next step.</p>
          <ul>
            <li>Save the password when your password manager offers it.</li>
            <li>Keep the authenticator in a securely synced app or add it to a second device.</li>
            <li>There is no email, SMS, or backup-code fallback.</li>
          </ul>
        </div>
        <button disabled={busy} onClick={() => setStage("credentials")}>
          Create account
        </button>
        <button className="text-button" disabled={busy} onClick={onExistingAccount}>
          Already have an account? Sign in & connect this Mac
        </button>
        <button className="text-button" disabled={busy} onClick={() => void cancel()}>
          Cancel setup
        </button>
        {error ? <small role="alert">{error}</small> : null}
      </section>
    );
  }

  if (stage === "credentials") {
    return (
      <section className="account-access account-signup account-enrollment">
        <span>STEP 1 OF 2 · ACCOUNT</span>
        <h2>Choose your credentials</h2>
        <p>Use a password manager to create and save a unique password for TerminalDB.</p>
        <form onSubmit={(event) => {
          event.preventDefault();
          void submitCredentials();
        }}>
          <label htmlFor="account-signup-username">Username</label>
          <input
            id="account-signup-username"
            autoCapitalize="none"
            autoComplete="username"
            autoCorrect="off"
            disabled={busy}
            maxLength={128}
            required
            value={username}
            onChange={(event) => setUsername(event.target.value)}
          />
          <label htmlFor="account-signup-password">Password</label>
          <input
            id="account-signup-password"
            autoComplete="new-password"
            disabled={busy}
            minLength={12}
            required
            type="password"
            value={password}
            onChange={(event) => setPassword(event.target.value)}
          />
          <small>At least 12 characters with upper and lowercase letters, a number, and a symbol.</small>
          <label htmlFor="account-signup-password-confirmation">Confirm password</label>
          <input
            id="account-signup-password-confirmation"
            autoComplete="new-password"
            disabled={busy}
            minLength={12}
            required
            type="password"
            value={passwordConfirmation}
            onChange={(event) => setPasswordConfirmation(event.target.value)}
          />
          <button disabled={busy} type="submit">
            {busy ? "Creating account…" : "Continue to authenticator setup"}
          </button>
        </form>
        <button className="text-button" disabled={busy} onClick={() => setStage("intro")}>Back</button>
        <button className="text-button" disabled={busy} onClick={() => void cancel()}>Cancel setup</button>
        {error ? <small role="alert">{error}</small> : null}
      </section>
    );
  }

  const formattedSecret = enrollment?.secret.match(/.{1,4}/gu)?.join(" ") ?? "";
  return (
    <section className="account-access account-signup account-enrollment account-totp-enrollment">
      <span>STEP 2 OF 2 · AUTHENTICATOR</span>
      <h2>Secure your account</h2>
      <p>Scan the QR code or copy the setup key. Then enter the current six-digit code from your authenticator app.</p>
      <div className="account-totp-setup">
        <div className="account-totp-qr">
          {qrCode
            ? <img alt="TerminalDB authenticator QR code" height="224" src={qrCode} width="224" />
            : <span aria-live="polite">Preparing QR code…</span>}
        </div>
        <div className="account-totp-key">
          <span>MANUAL SETUP KEY</span>
          <code aria-label="Authenticator setup key">{formattedSecret}</code>
          <button disabled={busy} type="button" onClick={() => void copySetupKey()}>
            Copy setup key
          </button>
          <small role="status">{copyStatus ?? "Keep this key private. It provides access to your authenticator codes."}</small>
        </div>
      </div>
      <form onSubmit={(event) => {
        event.preventDefault();
        void verifyAuthenticator();
      }}>
        <label htmlFor="account-authenticator-code">Six-digit code</label>
        <input
          id="account-authenticator-code"
          aria-describedby="account-authenticator-help"
          autoComplete="one-time-code"
          disabled={busy}
          inputMode="numeric"
          maxLength={6}
          pattern="[0-9]{6}"
          required
          value={authenticatorCode}
          onChange={(event) => setAuthenticatorCode(event.target.value.replace(/\D/gu, ""))}
        />
        <small id="account-authenticator-help">Codes change every 30 seconds. If one expires, enter the next code.</small>
        <button disabled={busy} type="submit">
          {busy ? "Verifying…" : "Finish account setup"}
        </button>
      </form>
      <button className="text-button" disabled={busy} onClick={() => void cancel()}>Cancel setup</button>
      {error ? <small role="alert">{error}</small> : null}
    </section>
  );
}

function AccountAccess({
  configuration,
  onSessionReady,
  context = "landing",
  activeAccessMode,
  accountBootstrapSupport = "checking",
  bootstrapToken,
  onRequestBootstrap,
  onBootstrapConsumed,
}: {
  readonly configuration: NonNullable<RemotePublicConfiguration["accountAuth"]>;
  readonly onSessionReady: () => Promise<void>;
  readonly context?: "landing" | "session";
  readonly activeAccessMode?: "pairing" | "account";
  readonly accountBootstrapSupport?: AccountBootstrapSupport;
  readonly bootstrapToken?: string | undefined;
  readonly onRequestBootstrap?: () => Promise<void>;
  readonly onBootstrapConsumed?: () => void;
}) {
  const [accessToken, setAccessToken] = useState<string>();
  const [devices, setDevices] = useState<readonly AccountDeviceSummary[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string>();
  const initialAccountAction = new URLSearchParams(location.search).get("account");
  const marketingAccountCreation = initialAccountAction === "create" &&
    new URLSearchParams(location.search).get("source") === "marketing";
  const bootstrapIntent = initialAccountAction === "connect" ||
    new URLSearchParams(location.search).get("intent") === "connect"
    ? "connect"
    : "create";
  const [securityAction, setSecurityAction] = useState<"password" | "delete" | undefined>(
    initialAccountAction === "password" || initialAccountAction === "delete"
      ? initialAccountAction
      : undefined,
  );
  const [signInPurpose, setSignInPurpose] = useState<
    "default" | "connect" | "password" | "delete" | undefined
  >();
  const [deleteConfirmation, setDeleteConfirmation] = useState("");
  const [currentPassword, setCurrentPassword] = useState("");
  const [nextPassword, setNextPassword] = useState("");
  const [nextPasswordConfirmation, setNextPasswordConfirmation] = useState("");
  const [accountActionBusy, setAccountActionBusy] = useState(false);
  const [bootstrapRequestBusy, setBootstrapRequestBusy] = useState(false);
  const [bootstrapComplete, setBootstrapComplete] = useState(false);
  const bootstrapCompletionRequestedRef = useRef(false);
  const bootstrapReauthenticationRequestedRef = useRef(false);
  const securityReauthenticationRequestedRef = useRef(false);

  const refresh = useCallback(async () => {
    setLoading(true);
    setError(undefined);
    try {
      const token = await accountAccessToken(configuration);
      setAccessToken(token);
      setDevices(token ? await listAccountDevices(token) : []);
    } catch (refreshError) {
      const message = refreshError instanceof Error
        ? refreshError.message
        : "Your Macs could not be loaded.";
      if (/\(401\)$/u.test(message)) {
        clearAccountCredentials();
        setAccessToken(undefined);
        setDevices([]);
        setError("Account access changed. Sign in again.");
      } else {
        setError(message);
      }
    } finally {
      setLoading(false);
    }
  }, [configuration]);

  useEffect(() => {
    void refresh();
  }, [refresh]);

  useEffect(() => {
    if (!accessToken) return;
    let cancelled = false;
    const timer = window.setInterval(() => {
      void (async () => {
        const token = await accountAccessToken(configuration);
        if (!token) return;
        const discovered = await listAccountDevices(token);
        if (!cancelled) {
          setAccessToken(token);
          setDevices(discovered);
        }
      })().catch((refreshError: unknown) => {
        const message = refreshError instanceof Error ? refreshError.message : "";
        if (/\(401\)$/u.test(message)) {
          clearAccountCredentials();
          setAccessToken(undefined);
          setDevices([]);
          setError("Account access changed. Sign in again.");
        }
      });
    }, 5_000);
    return () => {
      cancelled = true;
      window.clearInterval(timer);
    };
  }, [accessToken, configuration]);

  useEffect(() => {
    if (!accessToken || !bootstrapToken || bootstrapCompletionRequestedRef.current) return;
    if (!hasRecentAccountAuthentication(accessToken)) {
      if (bootstrapReauthenticationRequestedRef.current) return;
      bootstrapReauthenticationRequestedRef.current = true;
      savePendingAccountBootstrap(bootstrapToken);
      setSignInPurpose("connect");
      return;
    }
    bootstrapCompletionRequestedRef.current = true;
    void completeAccountBootstrap({ accessToken, bootstrapToken }).then(() => {
      clearPendingAccountBootstrap();
      setBootstrapComplete(true);
      onBootstrapConsumed?.();
      window.setTimeout(() => void refresh(), 1_500);
    }).catch((completionError: unknown) => {
      bootstrapCompletionRequestedRef.current = false;
      setError(completionError instanceof Error
        ? completionError.message
        : "This Mac could not be connected to the account.");
    });
  }, [accessToken, bootstrapIntent, bootstrapToken, configuration, onBootstrapConsumed, refresh]);

  useEffect(() => {
    if (!securityAction || loading || (accessToken && hasRecentAccountAuthentication(accessToken))) {
      return;
    }
    if (securityReauthenticationRequestedRef.current) return;
    securityReauthenticationRequestedRef.current = true;
    setSignInPurpose(securityAction);
  }, [accessToken, loading, securityAction]);

  const cancelAccountSetup = async () => {
    if (!bootstrapToken) return;
    setAccountActionBusy(true);
    setError(undefined);
    try {
      await cancelAccountBootstrap(bootstrapToken);
      clearPendingAccountBootstrap();
      onBootstrapConsumed?.();
    } catch (cancelError) {
      setError(cancelError instanceof Error
        ? cancelError.message
        : "Account setup could not be canceled.");
    } finally {
      setAccountActionBusy(false);
    }
  };

  const openSession = async (sessionId: string) => {
    if (!accessToken) return;
    setLoading(true);
    setError(undefined);
    try {
      await openAccountSession({ sessionId, accessToken });
      await onSessionReady();
    } catch (openError) {
      setError(openError instanceof Error ? openError.message : "The terminal session could not be opened.");
      setLoading(false);
    }
  };

  const clearAccountControllerIfNeeded = async () => {
    if (context !== "session" || activeAccessMode === "account") {
      await clearControllerSession();
    }
  };

  const logOut = async () => {
    setAccountActionBusy(true);
    setError(undefined);
    try {
      await clearAccountControllerIfNeeded();
      await signOutAccount(configuration);
    } catch (logoutError) {
      setError(logoutError instanceof Error ? logoutError.message : "The account could not be logged out.");
      setAccountActionBusy(false);
    }
  };

  const deleteAccount = async () => {
    if (deleteConfirmation !== "DELETE") return;
    if (!accessToken || !hasRecentAccountAuthentication(accessToken)) {
      await beginSecurityAction("delete");
      return;
    }
    setAccountActionBusy(true);
    setError(undefined);
    try {
      await deleteTerminalDBAccount(accessToken);
      await clearAccountControllerIfNeeded();
      await signOutAccount(configuration);
    } catch (deletionError) {
      setError(deletionError instanceof Error ? deletionError.message : "The account could not be deleted.");
      setAccountActionBusy(false);
    }
  };

  const beginSecurityAction = async (action: "password" | "delete") => {
    setSecurityAction(action);
    history.replaceState({}, "", `/?account=${action}`);
    if (accessToken && hasRecentAccountAuthentication(accessToken)) return;
    securityReauthenticationRequestedRef.current = true;
    setSignInPurpose(action);
  };

  const cancelSecurityAction = () => {
    setSecurityAction(undefined);
    setDeleteConfirmation("");
    setCurrentPassword("");
    setNextPassword("");
    setNextPasswordConfirmation("");
    history.replaceState({}, "", "/");
  };

  const updatePassword = async () => {
    if (!accessToken || !hasRecentAccountAuthentication(accessToken)) {
      await beginSecurityAction("password");
      return;
    }
    if (nextPassword !== nextPasswordConfirmation) {
      setError("The new passwords do not match.");
      return;
    }
    setAccountActionBusy(true);
    setError(undefined);
    try {
      await changeAccountPassword({
        configuration,
        accessToken,
        currentPassword,
        newPassword: nextPassword,
      });
      await recordAccountPasswordChanged(accessToken);
      setCurrentPassword("");
      setNextPassword("");
      setNextPasswordConfirmation("");
      await clearAccountControllerIfNeeded();
      await signOutAccount(configuration);
    } catch (passwordError) {
      setError(passwordError instanceof Error
        ? passwordError.message
        : "The password could not be changed.");
      setAccountActionBusy(false);
    }
  };

  const finishSignIn = (token: string) => {
    setAccessToken(token);
    setSignInPurpose(undefined);
    setError(undefined);
    void listAccountDevices(token).then(setDevices).catch((refreshError: unknown) => {
      setError(refreshError instanceof Error ? refreshError.message : "Your Macs could not be loaded.");
    });
  };

  if (loading && !accessToken && !bootstrapToken && !signInPurpose) {
    return <SessionLoadingView connectionState="connecting" />;
  }

  if (signInPurpose) {
    return (
      <AccountSignIn
        configuration={configuration}
        onComplete={finishSignIn}
        onRecover={() => {
          setSignInPurpose(undefined);
          setError("Open TerminalDB on an enrolled Mac, choose Remote Control, then Change Password. The Mac will open a one-time reset page here.");
        }}
        onCancel={() => {
          const securitySignIn = signInPurpose === "password" || signInPurpose === "delete";
          setSignInPurpose(undefined);
          if (signInPurpose === "connect") {
            bootstrapReauthenticationRequestedRef.current = false;
          }
          if (securitySignIn) cancelSecurityAction();
        }}
      />
    );
  }

  if (!accessToken) {
    if (bootstrapToken) {
      if (bootstrapIntent === "connect") {
        return (
          <section className="account-access account-signup">
            <span>MAC APPROVED · FRESH SIGN-IN REQUIRED</span>
            <h2>Connect this Mac</h2>
            <p>Sign in with your TerminalDB password and authenticator code. This one-time Mac approval expires automatically and cannot be reused.</p>
            <div className="account-security-notice">
              <strong>Your credentials stay with Cognito</strong>
              <p>TerminalDB receives only the verified account identity needed to bind this Mac's non-exportable key. It never receives your password or authenticator secret.</p>
            </div>
            <button
              disabled={loading || accountActionBusy}
              onClick={() => {
                savePendingAccountBootstrap(bootstrapToken);
                setSignInPurpose("connect");
              }}
            >
              Sign in & connect this Mac
            </button>
            <button
              className="text-button"
              disabled={accountActionBusy}
              onClick={() => void cancelAccountSetup()}
            >
              Cancel setup
            </button>
            <small>Need a new account instead? Return to TerminalDB and choose Create Account.</small>
            {error ? <small role="alert">{error}</small> : null}
          </section>
        );
      }
      return (
        <AccountEnrollment
          bootstrapToken={bootstrapToken}
          configuration={configuration}
          onCancel={cancelAccountSetup}
          onComplete={finishSignIn}
          onExistingAccount={() => {
            savePendingAccountBootstrap(bootstrapToken);
            setSignInPurpose("connect");
          }}
        />
      );
    }
    if (marketingAccountCreation) {
      return (
        <section className="account-access account-marketing-signup">
          <span>SECURE MAC APPROVAL REQUIRED</span>
          <h2>Create your account from TerminalDB</h2>
          <p>TerminalDB accounts begin from a Mac so a website cannot create an account and claim access to someone else’s terminals.</p>
          <ol>
            <li>Open TerminalDB on your Mac.</li>
            <li>Choose <strong>TerminalDB → Remote Control</strong>.</li>
            <li>Select <strong>Create Account</strong>. Your browser will return here with that Mac’s one-time approval.</li>
          </ol>
          <a
            className="account-download-link"
            href="https://github.com/danb235/TerminalDB/releases/download/v0.1.0/TerminalDB-macOS.zip"
          >
            Download TerminalDB for macOS
          </a>
          <button
            disabled={loading}
            onClick={() => setSignInPurpose("default")}
          >
            Already have an account? Log in
          </button>
          <small>Passwords and authenticator codes go directly to AWS Cognito. TerminalDB receives only your verified account identity.</small>
          {error ? <small role="alert">{error}</small> : null}
        </section>
      );
    }
    return (
      <section className="account-access">
        <span>YOUR TERMINALS, ANYWHERE</span>
        <h2>Sign in to TerminalDB</h2>
        <p>{context === "session"
          ? accountBootstrapSupport === "upgrade-required"
            ? "Sign in with an existing account. Creating a new account requires an updated TerminalDB app on this Mac."
            : "Sign in, or create an account with this Mac's one-time approval. Your current secure-link session stays active while you decide."
          : "Sign in to see every Mac connected to your account. To create an account, start from TerminalDB on a Mac or from an open one-time session."}</p>
        <small className="account-mfa-note">Every sign-in requires a six-digit code from your authenticator app.</small>
        <div className="account-auth-actions">
          <button
            disabled={loading}
            onClick={() => setSignInPurpose("default")}
          >
            Sign in
          </button>
          {context === "session" && activeAccessMode === "pairing" && onRequestBootstrap &&
          accountBootstrapSupport !== "upgrade-required" ? (
            <button
              disabled={loading || bootstrapRequestBusy || accountBootstrapSupport === "checking"}
              onClick={() => {
                setBootstrapRequestBusy(true);
                setError(undefined);
                void onRequestBootstrap().catch((bootstrapError: unknown) => {
                  setError(bootstrapError instanceof Error
                    ? bootstrapError.message
                    : "The Mac could not approve account creation.");
                }).finally(() => setBootstrapRequestBusy(false));
              }}
            >
              {bootstrapRequestBusy
                ? "Waiting for Mac…"
                : accountBootstrapSupport === "checking"
                  ? "Checking Mac…"
                  : "Create account with this Mac"}
            </button>
          ) : null}
        </div>
        {context === "session" && activeAccessMode === "pairing" &&
        accountBootstrapSupport === "upgrade-required" ? (
          <div className="account-compatibility" role="alert">
            <strong>Update TerminalDB on this Mac</strong>
            <span>This one-time session came from an older Mac app that cannot approve account creation. Install TerminalDB v0.3.0 or newer, then reopen Remote Control. Sign-in and this one-time terminal remain available.</span>
          </div>
        ) : null}
        {error ? <small role="alert">{error}</small> : null}
      </section>
    );
  }

  if (securityAction === "password") {
    return (
      <section className="account-access account-security-action">
        <span>RECENT PASSWORD + AUTHENTICATOR REQUIRED</span>
        <h2>Change your password</h2>
        <p>Your passwords are sent directly from this browser to AWS Cognito. TerminalDB is notified only after Cognito accepts the change so it can sign out trusted browsers.</p>
        <form onSubmit={(event) => {
          event.preventDefault();
          void updatePassword();
        }}>
          <label htmlFor="account-current-password">Current password</label>
          <input
            id="account-current-password"
            type="password"
            autoComplete="current-password"
            value={currentPassword}
            onChange={(event) => setCurrentPassword(event.target.value)}
            disabled={accountActionBusy}
            required
          />
          <label htmlFor="account-new-password">New password</label>
          <input
            id="account-new-password"
            type="password"
            autoComplete="new-password"
            value={nextPassword}
            onChange={(event) => setNextPassword(event.target.value)}
            disabled={accountActionBusy}
            minLength={12}
            required
          />
          <small>At least 12 characters with upper and lowercase letters, a number, and a symbol.</small>
          <label htmlFor="account-new-password-confirmation">Confirm new password</label>
          <input
            id="account-new-password-confirmation"
            type="password"
            autoComplete="new-password"
            value={nextPasswordConfirmation}
            onChange={(event) => setNextPasswordConfirmation(event.target.value)}
            disabled={accountActionBusy}
            minLength={12}
            required
          />
          <button disabled={accountActionBusy} type="submit">
            {accountActionBusy ? "Changing password…" : "Change password & sign out browsers"}
          </button>
        </form>
        <button className="text-button" disabled={accountActionBusy} onClick={cancelSecurityAction}>
          Cancel
        </button>
        <small>Your existing authenticator-app TOTP remains required at the next sign-in.</small>
        {error ? <small role="alert">{error}</small> : null}
      </section>
    );
  }

  if (securityAction === "delete") {
    return (
      <section className="account-access account-security-action account-danger-zone">
        <span>RECENT PASSWORD + AUTHENTICATOR REQUIRED</span>
        <h2>Delete your TerminalDB account?</h2>
        <p>This permanently removes your Cognito login, enrolled Macs, active account sessions, and trusted account browsers. One-time sessions that were never connected to the account are not affected.</p>
        <label htmlFor="delete-account-confirmation">Type DELETE to confirm</label>
        <input
          id="delete-account-confirmation"
          autoComplete="off"
          spellCheck={false}
          value={deleteConfirmation}
          onChange={(event) => setDeleteConfirmation(event.target.value)}
          disabled={accountActionBusy}
        />
        <div>
          <button
            disabled={accountActionBusy || deleteConfirmation !== "DELETE"}
            onClick={() => void deleteAccount()}
          >
            {accountActionBusy ? "Deleting…" : "Permanently delete account"}
          </button>
          <button disabled={accountActionBusy} onClick={cancelSecurityAction}>Cancel</button>
        </div>
        {error ? <small role="alert">{error}</small> : null}
      </section>
    );
  }

  return (
    <section className={`account-access account-access-signed-in ${context === "landing" ? "account-home" : ""}`}>
      <header>
        <div>
          <span>{context === "landing" ? "TERMINALDB REMOTE" : "YOUR TERMINALDB ACCOUNT"}</span>
          <h2>{context === "landing" ? "Devices & sessions" : "Your Macs"}</h2>
          {context === "landing" ? <p>Every enrolled Mac and its availability in one place. Select an online Mac to view its windows and terminal tabs.</p> : null}
        </div>
        <button
          className="text-button"
          disabled={accountActionBusy}
          onClick={() => void logOut()}
        >
          Log out
        </button>
      </header>
      {bootstrapComplete ? (
        <p className="account-success">Mac enrolled. It will appear online as soon as its encrypted session connects.</p>
      ) : null}
      {devices.length > 0 && devices.every((device) => device.state === "offline") ? (
        <div className="account-offline-notice" role="status">
          <strong>You’re signed in. No Macs are online.</strong>
          <span>Open TerminalDB on an enrolled Mac. It will reconnect automatically and its terminals will become available here.</span>
        </div>
      ) : null}
      {devices.length > 0 ? (
        <div className="account-device-list">
          {devices.map((device) => {
            const online = device.state === "online" && Boolean(device.sessionId);
            const content = (
              <>
                <span className={`device-state device-state-${device.state}`} aria-hidden="true" />
                <span className="account-device-details">
                  <b>{device.deviceName}</b>
                  <small>{device.state === "online"
                    ? `Online · Session started ${new Date((device.sessionCreatedAt ?? 0) * 1_000).toLocaleString()}`
                    : device.state === "connecting"
                      ? "Connecting securely…"
                      : `Offline · ${accountDeviceActivityLabel(device.lastSeenAt)}`}</small>
                </span>
                <strong>{online ? "Open" : device.state === "connecting" ? "Connecting" : "Offline"}</strong>
              </>
            );
            return online ? (
              <button
                key={device.deviceId}
                disabled={loading}
                onClick={() => void openSession(device.sessionId!)}
              >
                {content}
              </button>
            ) : (
              <article key={device.deviceId}>{content}</article>
            );
          })}
        </div>
      ) : (
        <p>No Macs are enrolled yet. Open TerminalDB on a Mac and choose Connect Account.</p>
      )}
      <small className="account-privacy-detail">Terminal names and counts remain end-to-end encrypted and appear when you select an online Mac.</small>
      <small className="account-privacy-detail">To add another Mac, open TerminalDB on that Mac and choose Connect Account. No enrollment code is needed.</small>
      <div className="account-actions">
        <button disabled={loading} onClick={() => void refresh()}>Refresh Macs</button>
        <button disabled={accountActionBusy} onClick={() => void beginSecurityAction("password")}>
          Change password
        </button>
      </div>
      <div className="account-danger-zone">
        <button disabled={accountActionBusy} onClick={() => void beginSecurityAction("delete")}>
          Delete account
        </button>
      </div>
      {error ? <small role="alert">{error}</small> : null}
    </section>
  );
}

function UnpairedView({
  checking,
  configuration,
  onSessionReady,
  bootstrapToken,
  onBootstrapConsumed,
}: {
  readonly checking: boolean;
  readonly configuration: RemotePublicConfiguration | undefined;
  readonly onSessionReady: () => Promise<void>;
  readonly bootstrapToken?: string | undefined;
  readonly onBootstrapConsumed: () => void;
}) {
  const accountRequested = new URLSearchParams(location.search).has("account");
  if (!checking && configuration?.accountAuth) {
    return (
      <AccountAccess
        configuration={configuration.accountAuth}
        onSessionReady={onSessionReady}
        bootstrapToken={bootstrapToken}
        onBootstrapConsumed={onBootstrapConsumed}
      />
    );
  }
  return (
    <main className="pairing-view">
      <AppMark />
      <span className="eyebrow">TERMINALDB REMOTE</span>
      <h1>{checking ? "Checking this browser…" : "Open your terminals"}</h1>
      <p>
        {checking
          ? "Looking for a trusted controller identity on this device."
          : "Sign in to your account, or keep using a one-time secure link from TerminalDB."}
      </p>
      {!checking && configuration && !configuration.accountAuth && accountRequested ? (
        <section className="account-access account-access-unavailable">
          <span>TERMINALDB ACCOUNT</span>
          <h2>Accounts are not configured</h2>
          <p>This deployment has not enabled Cognito accounts. Ask its operator to configure accounts, or continue with a one-time link.</p>
        </section>
      ) : null}
      <div className="pairing-proof">
        <div><span>TERMINAL DATA</span><strong>Remains on your Mac</strong></div>
        <div><span>PAIRING</span><strong>Single-use · 10 minutes</strong></div>
        <div><span>SECURITY</span><strong>End-to-end encrypted</strong></div>
      </div>
      <small>One-time links still work without an account. Terminal content remains end-to-end encrypted in both modes.</small>
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
  onControls,
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
  readonly onControls: () => void;
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
        <button className="terminal-back" onClick={onBack} aria-label="Back to devices and sessions">‹</button>
        <div className="terminal-window-title">
          <strong>{tab.title}</strong>
          <div className="terminal-window-context">
            <code title={tab.directory}>{tab.directory}</code>
            {tab.model ? <span title={`Active Claude model: ${tab.model}`}>{tab.model}</span> : null}
          </div>
        </div>
        <ConnectionPill state={state} onClick={onDiagnostics} />
        <button
          className="account-chip"
          onClick={onAccounts}
          aria-label="Accounts"
          title={`TerminalDB and Claude accounts · Active Claude account: ${tab.accountLabel ?? "None"}`}
        >
          <span aria-hidden="true">◎</span>
          <span className="account-chip-label">Accounts</span>
        </button>
        <button className="terminal-more" onClick={onControls} aria-label="Remote controls">•••</button>
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
  remoteAccountConfiguration,
  onRemoteSessionReady,
  activeAccessMode,
  accountBootstrapSupport,
  bootstrapToken,
  onRequestBootstrap,
  onBootstrapConsumed,
}: {
  readonly accounts: readonly ClaudeAccount[];
  readonly selectedTab: RemoteTab | undefined;
  readonly onSwitch: (account: ClaudeAccount) => void;
  readonly onRefresh: () => void;
  readonly refreshing: boolean;
  readonly canControl: boolean;
  readonly remoteAccountConfiguration: NonNullable<RemotePublicConfiguration["accountAuth"]> | undefined;
  readonly onRemoteSessionReady: () => Promise<void>;
  readonly activeAccessMode: "pairing" | "account";
  readonly accountBootstrapSupport: AccountBootstrapSupport;
  readonly bootstrapToken?: string | undefined;
  readonly onRequestBootstrap: () => Promise<void>;
  readonly onBootstrapConsumed: () => void;
}) {
  const sortedAccounts = stableClaudeAccounts(accounts);
  return (
    <section className="view accounts-view" aria-labelledby="accounts-heading">
      <header className="page-heading">
        <span className="eyebrow">TERMINALDB</span>
        <h1 id="accounts-heading">Accounts</h1>
        <p>{activeAccessMode === "pairing"
          ? accountBootstrapSupport === "upgrade-required"
            ? "Sign in without giving up this one-time session. Update the Mac app before creating a new account."
            : "Create or sign in to your TerminalDB account without giving up this one-time session."
          : "Manage your TerminalDB sessions and the Claude accounts available on this Mac."}</p>
      </header>
      {remoteAccountConfiguration ? (
        <AccountAccess
          configuration={remoteAccountConfiguration}
          onSessionReady={onRemoteSessionReady}
          context="session"
          activeAccessMode={activeAccessMode}
          accountBootstrapSupport={accountBootstrapSupport}
          bootstrapToken={bootstrapToken}
          onRequestBootstrap={onRequestBootstrap}
          onBootstrapConsumed={onBootstrapConsumed}
        />
      ) : (
        <section className="account-access account-access-unavailable">
          <span>TERMINALDB ACCOUNT</span>
          <h2>Accounts are not configured</h2>
          <p>This self-hosted deployment has not enabled Cognito accounts. One-time links continue to work normally.</p>
        </section>
      )}
      <div className="account-section-heading">
        <span className="eyebrow">CLAUDE CODE ON THIS MAC</span>
        <h2>Claude accounts & usage</h2>
        <p>Select the subscription for this terminal tab. Its credentials never leave the Mac.</p>
      </div>
      <div
        className="account-list"
        role="radiogroup"
        aria-label="Claude subscription for this terminal tab"
      >
        {sortedAccounts.map((account) => {
          const active = account.id === selectedTab?.accountId;
          const disabled = !active && (
            selectedTab?.busy === true || !canControl || !account.signedIn
          );
          const stateLabel = active
            ? "Active on this tab"
            : !account.signedIn
              ? "Sign in on Mac"
              : selectedTab?.busy
                ? "Tab is busy"
                : !canControl
                  ? "Remote unavailable"
                  : "Use on this tab";
          return (
            <label
              className={`account-row ${active ? "active" : ""} ${disabled ? "disabled" : ""}`}
              key={account.id}
              data-account-id={account.id}
            >
              <input
                className="account-radio"
                type="radio"
                name={`claude-account-${selectedTab?.id ?? "terminal"}`}
                checked={active}
                disabled={disabled}
                onChange={() => {
                  if (!active) onSwitch(account);
                }}
                aria-label={`${account.label}: ${stateLabel}`}
              />
              <div className="account-row-identity">
                <div className="account-avatar" aria-hidden="true">
                  {account.label.slice(0, 2).toUpperCase()}
                </div>
                <div>
                  <strong>{account.label}</strong>
                  <small>{account.email ?? "Account on this Mac"}</small>
                </div>
              </div>
              <div className="account-usage-grid" aria-label={`${account.label} usage`}>
                {stableClaudeUsage(account).map((usage, index) => {
                  const label = CLAUDE_USAGE_LABELS[index];
                  return (
                    <div className="account-usage" key={label}>
                      <div>
                        <span>{label}</span>
                        <b>{usage ? `${usage.utilization}%` : "—"}</b>
                      </div>
                      <div className="usage-bar">
                        <i style={{ width: `${usage?.utilization ?? 0}%` }} />
                      </div>
                      <small title={usage?.resetsAt ? `Resets ${usage.resetsAt}` : "Reset unavailable"}>
                        {usage?.resetsAt ? `Resets ${usage.resetsAt}` : "Reset unavailable"}
                      </small>
                    </div>
                  );
                })}
              </div>
              <div className="account-row-state">
                {account.plan ? <span>{account.plan}</span> : null}
                <strong>{stateLabel}</strong>
              </div>
            </label>
          );
        })}
        {sortedAccounts.length === 0 ? (
          <p className="account-list-empty">No Claude subscriptions are authenticated on this Mac.</p>
        ) : null}
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

function RemoteControlsView({
  state,
  onRevoke,
  onEndSession,
  onSwitchSession,
}: {
  readonly state: ReturnType<typeof useConnectionModel>[0];
  readonly onRevoke: () => void;
  readonly onEndSession: () => void;
  readonly onSwitchSession?: (() => void) | undefined;
}) {
  const sessionEnded = ["remote-ended", "revoked", "update-required"].includes(
    state.state,
  );
  const canEndSession = state.state === "live" || state.state === "slow";
  return (
    <section className="view devices-view" aria-labelledby="controls-heading">
      <header className="page-heading">
        <span className="eyebrow">REMOTE CONTROL</span>
        <h1 id="controls-heading">Trusted controllers</h1>
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
      {onSwitchSession ? (
        <button className="wide-secondary" onClick={onSwitchSession}>
          Open another account session
        </button>
      ) : null}
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
  const devSearch = import.meta.env.DEV ? new URLSearchParams(location.search) : undefined;
  const devInventoryMode = import.meta.env.DEV
    ? devSearch?.get("inventory") ?? null
    : null;
  const forceSessionsHome = devSearch?.has("sessions") === true;
  const forceUnpaired =
    import.meta.env.DEV &&
    devSearch?.has("unpaired") === true;
  const [view, setView] = useState<View>(
    import.meta.env.DEV && !forceUnpaired && !devInventoryMode && !forceSessionsHome
      ? "terminal"
      : "dashboard",
  );
  const [connection, dispatch] = useConnectionModel();
  const mockCapabilities = import.meta.env.DEV
    ? (window as Window & { __terminaldbMockCapabilities?: readonly string[] })
      .__terminaldbMockCapabilities
    : undefined;
  const initialInventory: InventoryPayload = import.meta.env.DEV && !devInventoryMode
    ? mockCapabilities !== undefined
      ? { ...mockInventory, capabilities: mockCapabilities }
      : mockInventory
    : { instances: [], accounts: [] };
  const [inventory, setInventory] = useState<InventoryPayload>(initialInventory);
  const [inventoryPhase, setInventoryPhase] = useState<InventoryPhase>(
    import.meta.env.DEV && devInventoryMode !== "loading" ? "ready" : "loading",
  );
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
  const [remoteConfiguration, setRemoteConfiguration] = useState<RemotePublicConfiguration>();
  const [activeAccessMode, setActiveAccessMode] = useState<"pairing" | "account">("pairing");
  const activeAccessModeRef = useRef<"pairing" | "account">("pairing");
  const [activeRemoteSessionId, setActiveRemoteSessionId] = useState<string>();
  const [accountDevices, setAccountDevices] = useState<readonly AccountDeviceSummary[]>([]);
  const [accountDevicesLoading, setAccountDevicesLoading] = useState(false);
  const [accountDevicesError, setAccountDevicesError] = useState<string>();
  const [switchingDeviceId, setSwitchingDeviceId] = useState<string>();
  const [accountBootstrapToken, setAccountBootstrapToken] = useState<string | undefined>(() => {
    const fragment = new URLSearchParams(location.hash.replace(/^#/u, ""));
    const approved = fragment.get("account-bootstrap") ?? undefined;
    if (approved) {
      savePendingAccountBootstrap(approved);
      history.replaceState({}, "", `${location.pathname}${location.search}`);
      return approved;
    }
    return pendingAccountBootstrap();
  });
  const [accountPasswordResetToken, setAccountPasswordResetToken] = useState<string | undefined>(() => {
    const fragment = new URLSearchParams(location.hash.replace(/^#/u, ""));
    const approved = fragment.get("account-password-reset") ?? undefined;
    if (approved) {
      history.replaceState({}, "", `${location.pathname}${location.search}`);
    }
    return approved;
  });
  const passwordResetRequested =
    new URLSearchParams(location.search).get("account") === "reset-password";
  const clientRef = useRef<RemoteClient | null>(null);
  const connectionEpochRef = useRef(0);
  const inventoryReadyRef = useRef(
    import.meta.env.DEV && devInventoryMode !== "loading",
  );
  const emptyInventoryTimerRef = useRef<number | undefined>(undefined);
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
            ...(nextOutput.inputStreamId
              ? { inputStreamId: nextOutput.inputStreamId }
              : {}),
            ...(nextOutput.inputThrough !== undefined
              ? { inputThrough: nextOutput.inputThrough }
              : {}),
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
      if (emptyInventoryTimerRef.current) {
        window.clearTimeout(emptyInventoryTimerRef.current);
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
      setRemoteConfiguration(configuration);
      setRemoteRegion(configuration.region);
      if (configuration.accountAuth) {
        const completedAccountSignIn = await completeAccountSignIn(configuration.accountAuth);
        if (completedAccountSignIn) setView("dashboard");
        const accountQuery = new URLSearchParams(location.search);
        if (accountQuery.get("account") === "create" || accountQuery.get("account") === "finish") {
          setView("accounts");
        }
      }
      if (configuration.protocolVersion !== PROTOCOL_VERSION) {
        setAccessState((await loadControllerSession()) ? "paired" : "unpaired");
        dispatch({ type: "version-mismatch" });
        return;
      }
      const existingSession = await loadControllerSession();
      const existingAccessMode = existingSession?.accessMode === "account" ? "account" : "pairing";
      activeAccessModeRef.current = existingAccessMode;
      setActiveAccessMode(existingAccessMode);
      setActiveRemoteSessionId(existingAccessMode === "account" ? existingSession?.sessionId : undefined);
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
          if (nextTabs.length > 0 || inventoryReadyRef.current) {
            if (emptyInventoryTimerRef.current) {
              window.clearTimeout(emptyInventoryTimerRef.current);
              emptyInventoryTimerRef.current = undefined;
            }
            inventoryReadyRef.current = true;
            setInventoryPhase("ready");
          } else if (!emptyInventoryTimerRef.current) {
            // The agent can briefly publish an empty aggregate while its Mac
            // clients are registering. Keep a truthful loading state through
            // that hand-off instead of flashing "no sessions".
            emptyInventoryTimerRef.current = window.setTimeout(() => {
              if (epoch !== connectionEpochRef.current) return;
              inventoryReadyRef.current = true;
              setInventoryPhase("ready");
              emptyInventoryTimerRef.current = undefined;
            }, 900);
          }
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
            setView((currentView) => shouldOpenInitialTerminal(
              activeAccessModeRef.current,
              currentView,
            ) ? "terminal" : currentView);
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
        onAccountBootstrap: (bootstrapToken) => {
          if (epoch !== connectionEpochRef.current) return;
          savePendingAccountBootstrap(bootstrapToken);
          setAccountBootstrapToken(bootstrapToken);
          setView("accounts");
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
      if (paired) {
        const session = await loadControllerSession();
        const accessMode = session?.accessMode === "account" ? "account" : "pairing";
        activeAccessModeRef.current = accessMode;
        setActiveAccessMode(accessMode);
        setActiveRemoteSessionId(accessMode === "account" ? session?.sessionId : undefined);
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
    const configuration = remoteConfiguration?.accountAuth;
    if (accessState !== "paired" || activeAccessMode !== "account" || !configuration) {
      setAccountDevices([]);
      setAccountDevicesLoading(false);
      setAccountDevicesError(undefined);
      return;
    }
    let cancelled = false;
    const refresh = async (showProgress: boolean) => {
      if (showProgress && !cancelled) setAccountDevicesLoading(true);
      try {
        const token = await accountAccessToken(configuration);
        if (!token) throw new Error("Account sign-in has expired");
        const devices = await listAccountDevices(token);
        if (!cancelled) {
          setAccountDevices(devices);
          setAccountDevicesError(undefined);
        }
      } catch (error) {
        if (!cancelled) {
          setAccountDevicesError(error instanceof Error
            ? error.message
            : "Your devices could not be refreshed.");
        }
      } finally {
        if (!cancelled && showProgress) setAccountDevicesLoading(false);
      }
    };
    void refresh(true);
    const timer = window.setInterval(() => void refresh(false), 5_000);
    return () => {
      cancelled = true;
      window.clearInterval(timer);
    };
  }, [accessState, activeAccessMode, remoteConfiguration]);

  const openAccountDevice = useCallback(async (device: AccountDeviceSummary) => {
    if (!device.sessionId || device.sessionId === activeRemoteSessionId || switchingDeviceId) return;
    const configuration = remoteConfiguration?.accountAuth;
    if (!configuration) return;
    setSwitchingDeviceId(device.deviceId);
    setAccountDevicesError(undefined);
    try {
      const token = await accountAccessToken(configuration);
      if (!token) throw new Error("Sign in again to open this Mac.");
      const session = await openAccountSession({ sessionId: device.sessionId, accessToken: token });
      clientRef.current?.close();
      clientRef.current = null;
      setInventory({ instances: [], accounts: [] });
      inventoryReadyRef.current = false;
      setInventoryPhase("loading");
      selectedTabRef.current = undefined;
      setSelectedTabId(undefined);
      setActiveRemoteSessionId(session.sessionId);
      setView("dashboard");
      await connect();
    } catch (error) {
      setAccountDevicesError(error instanceof Error
        ? error.message
        : "This Mac could not be opened.");
    } finally {
      setSwitchingDeviceId(undefined);
    }
  }, [activeRemoteSessionId, connect, remoteConfiguration, switchingDeviceId]);

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
    const deliver = async (batch: SequencedInputBatch) => {
      terminalSurfacesRef.current.get(tabId)?.markOptimisticInputSent(batch);
      if (client) {
        await client.send("pty.input", {
          tabId,
          input: batch.input,
          inputStreamId: batch.inputStreamId,
          inputSequence: batch.inputSequence,
        });
        return;
      }
      const mockWindow = window as Window & {
        __terminaldbMockInputs?: string[];
        __terminaldbMockEchoDelayMs?: number;
        __terminaldbMockAckDelayMs?: number;
      };
      if (import.meta.env.DEV) {
        mockWindow.__terminaldbMockInputs ??= [];
        mockWindow.__terminaldbMockInputs.push(batch.input);
      }
      const mockEcho = batch.input.replaceAll("\r", "\r\n");
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
                inputStreamId: batch.inputStreamId,
                inputThrough: batch.inputSequence,
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
    const supportsSequencedInput =
      inventory.capabilities?.includes("sequenced-input-v1") === true;
    void inputDeliveryQueueRef.current?.enqueue(
      tabId,
      input,
      deliver,
      supportsSequencedInput,
    ).then((result) => {
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
    if (terminalInputTimerRef.current === undefined) {
      terminalInputTimerRef.current = window.setTimeout(
        flushTerminalInput,
        TERMINAL_INPUT_BATCH_DELAY_MS,
      );
    }
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
    const client = clientRef.current;
    if (!client && import.meta.env.DEV) {
      setInventory((current) => ({
        ...current,
        instances: current.instances.map((instance) => ({
          ...instance,
          tabs: instance.tabs.map((tab) => tab.id === selectedTab.id
            ? { ...tab, accountId: account.id, accountLabel: account.label }
            : tab),
        })),
      }));
      const mockWindow = window as Window & { __terminaldbMockAccountCommands?: string[] };
      mockWindow.__terminaldbMockAccountCommands ??= [];
      mockWindow.__terminaldbMockAccountCommands.push(
        `switch:${selectedTab.id}:${account.id}`,
      );
      return;
    }
    if (!client) return;
    try {
      await client.send("account.switch", {
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

  const requestAccountBootstrap = async () => {
    const client = clientRef.current;
    if (!client) throw new Error("The one-time session is not connected to the Mac.");
    if (!inventory.capabilities?.includes("account-bootstrap-v1")) {
      throw new Error("Update TerminalDB on this Mac before creating an account.");
    }
    await client.send("account.bootstrap", {}, 15_000, true);
  };

  const consumeAccountBootstrap = () => {
    clearPendingAccountBootstrap();
    setAccountBootstrapToken(undefined);
  };

  const finishPasswordReset = (_accessToken: string) => {
    setAccountPasswordResetToken(undefined);
    history.replaceState({}, "", "/?account");
    // The completed Cognito response proves password + existing TOTP. Keep
    // only the freshly returned session, then load the account dashboard.
    setView("accounts");
  };

  if (accountPasswordResetToken && remoteConfiguration?.accountAuth) {
    return (
      <main className="pairing-view account-reset-page">
        <AppMark />
        <AccountPasswordReset
          configuration={remoteConfiguration.accountAuth}
          resetToken={accountPasswordResetToken}
          onComplete={finishPasswordReset}
          onCancel={() => {
            setAccountPasswordResetToken(undefined);
            history.replaceState({}, "", "/?account");
          }}
        />
      </main>
    );
  }

  if (passwordResetRequested && !accountPasswordResetToken && remoteConfiguration?.accountAuth) {
    return (
      <main className="pairing-view account-reset-page">
        <AppMark />
        <section className="account-access account-enrollment account-signin">
          <span>RESET APPROVAL REQUIRED</span>
          <h2>Start again from TerminalDB</h2>
          <p>This password reset link expired or was already used. On an enrolled Mac, open Remote Control and choose Change Password.</p>
          <button onClick={() => history.replaceState({}, "", "/?account")}>Return to sign in</button>
        </section>
      </main>
    );
  }

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

  if (accessState === "checking") {
    return <SessionLoadingView connectionState={connection.state} />;
  }

  if (accessState !== "paired") {
    return (
      <UnpairedView
        checking={false}
        configuration={remoteConfiguration}
        onSessionReady={connect}
        bootstrapToken={accountBootstrapToken}
        onBootstrapConsumed={consumeAccountBootstrap}
      />
    );
  }

  const terminalWorkspace = Boolean(
    selectedTab && ["terminal", "accounts", "controls", "diagnostics"].includes(view),
  );
  const dashboardPresentation = dashboardSessionPresentation(
    inventoryPhase,
    allTabs.length,
    connection.state,
  );

  if (view === "dashboard" && dashboardPresentation === "loading") {
    return <SessionLoadingView connectionState={connection.state} />;
  }

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

      {view === "dashboard" ? (
        <Dashboard
          inventory={inventory}
          presentation={dashboardPresentation}
          accountDevices={accountDevices}
          activeSessionId={activeRemoteSessionId}
          devicesLoading={accountDevicesLoading}
          devicesError={accountDevicesError}
          switchingDeviceId={switchingDeviceId}
          onOpenTab={openTab}
          onOpenDevice={(device) => void openAccountDevice(device)}
        />
      ) : null}
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
          onControls={() => setView("controls")}
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
              remoteAccountConfiguration={remoteConfiguration?.accountAuth}
              onRemoteSessionReady={connect}
              activeAccessMode={activeAccessMode}
              accountBootstrapSupport={accountBootstrapSupport(inventory)}
              bootstrapToken={accountBootstrapToken}
              onRequestBootstrap={requestAccountBootstrap}
              onBootstrapConsumed={consumeAccountBootstrap}
            />
          ) : null}
          {view === "controls" ? (
            <RemoteControlsView
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
              onSwitchSession={activeAccessMode === "account"
                ? () => {
                    void (async () => {
                      clientRef.current?.close();
                      clientRef.current = null;
                      await clearControllerSession();
                      setInventory({ instances: [], accounts: [] });
                      inventoryReadyRef.current = false;
                      setInventoryPhase("loading");
                      setSelectedTabId(undefined);
                      setAccessState("unpaired");
                      setView("dashboard");
                    })();
                  }
                : undefined}
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
      {import.meta.env.DEV && view === "lab" ? <LabView model={connection} dispatch={dispatch} /> : null}

      {!terminalWorkspace ? <nav className="bottom-nav" aria-label="Remote sections">
        {[
          ["dashboard", "▦", "Home"],
          ["accounts", "●", "Accounts"],
          ...(import.meta.env.DEV ? [["lab", "⌁", "Lab"]] : []),
        ].map(([id, icon, label]) => (
          <button
            key={id}
            className={view === id ? "active" : ""}
            onClick={() => setView(id as View)}
          >
            <span>{icon}</span>
            {label}
          </button>
        ))}
      </nav> : null}
    </div>
  );
}
