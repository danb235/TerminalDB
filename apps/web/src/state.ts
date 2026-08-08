import type { ConnectionState } from "@terminaldb/protocol";

export interface ConnectionModel {
  readonly state: ConnectionState;
  readonly socketOpen: boolean;
  readonly synchronized: boolean;
  readonly rttMs?: number | undefined;
  readonly lastMacSeenAt?: number | undefined;
  readonly lastSyncAt?: number | undefined;
  readonly reconnectAttempt: number;
  readonly staleSince?: number | undefined;
  readonly detail?: string | undefined;
}

export type ConnectionAction =
  | { readonly type: "socket-open" }
  | { readonly type: "health"; readonly rttMs: number; readonly at?: number }
  | { readonly type: "socket-close"; readonly phoneOffline?: boolean; readonly at?: number }
  | { readonly type: "mac-stale"; readonly at?: number }
  | { readonly type: "resync-start" }
  | { readonly type: "resync-complete"; readonly at?: number }
  | { readonly type: "rotation-start" }
  | { readonly type: "delivery-uncertain"; readonly detail?: string | undefined }
  | { readonly type: "ended"; readonly revoked?: boolean }
  | { readonly type: "version-mismatch" }
  | {
      readonly type: "simulate";
      readonly state: ConnectionState;
      readonly rttMs?: number | undefined;
    }
  | { readonly type: "retry" };

export const initialConnection: ConnectionModel = {
  state: "connecting",
  socketOpen: false,
  synchronized: false,
  reconnectAttempt: 0,
};

const BACKGROUND_CONNECTION_STATES: readonly ConnectionState[] = [
  "resyncing",
  "rotating",
  "delivery-uncertain",
];

const INPUT_BLOCKING_STATES: readonly ConnectionState[] = [
  "connecting",
  "reconnecting",
  "delivery-uncertain",
  "phone-offline",
  "mac-offline",
  "remote-ended",
  "revoked",
  "update-required",
];

/**
 * A fresh screen remains safe to control while the client refreshes inventory,
 * rotates an authenticated socket, or resolves an acknowledgement in the
 * background. Keeping this separate from the diagnostic state prevents a
 * routine maintenance transition from blurring the terminal mid-command.
 * Uncertain input is the exception: later bytes must wait until the Mac has
 * resolved the earlier request or Return could execute a truncated command.
 */
export function canAcceptTerminalInput(model: ConnectionModel): boolean {
  return (
    model.socketOpen &&
    (model.synchronized || model.lastSyncAt !== undefined) &&
    !INPUT_BLOCKING_STATES.includes(model.state)
  );
}

/**
 * Routine maintenance is intentionally quiet in the primary terminal chrome.
 * The raw state and detail remain available in Connection Details.
 */
export function presentedConnectionState(model: ConnectionModel): ConnectionState {
  if (
    model.socketOpen &&
    model.lastSyncAt !== undefined &&
    BACKGROUND_CONNECTION_STATES.includes(model.state)
  ) {
    return (model.rttMs ?? 0) > 1_500 ? "slow" : "live";
  }
  return model.state;
}

export function connectionReducer(
  state: ConnectionModel,
  action: ConnectionAction,
): ConnectionModel {
  switch (action.type) {
    case "socket-open":
      return {
        ...state,
        state: "resyncing",
        socketOpen: true,
        synchronized: false,
        detail: "Secured. Requesting a fresh viewport.",
      };
    case "health": {
      const now = action.at ?? Date.now();
      const ready = state.socketOpen && state.synchronized;
      return {
        ...state,
        state: ready ? (action.rttMs > 1_500 ? "slow" : "live") : "resyncing",
        rttMs: action.rttMs,
        lastMacSeenAt: now,
        reconnectAttempt: 0,
        detail: ready ? undefined : "Mac is present. Waiting for a fresh inventory and viewport.",
      };
    }
    case "socket-close":
      return {
        ...state,
        state: action.phoneOffline ? "phone-offline" : "reconnecting",
        socketOpen: false,
        synchronized: false,
        staleSince: action.at ?? Date.now(),
        reconnectAttempt: state.reconnectAttempt + 1,
        detail: action.phoneOffline ? "This phone has no usable network." : "The relay connection closed.",
      };
    case "mac-stale":
      return {
        ...state,
        state: "mac-offline",
        synchronized: false,
        staleSince: action.at ?? Date.now(),
        detail: "AWS is reachable, but the Mac stopped responding.",
      };
    case "resync-start":
      if (state.state === "mac-offline") {
        return {
          ...state,
          synchronized: false,
          detail: "AWS is reachable, but the Mac has not reconnected yet.",
        };
      }
      return {
        ...state,
        state: "resyncing",
        synchronized: false,
        detail: "Fetching inventory and current viewport.",
      };
    case "resync-complete": {
      const synchronizedAt = action.at ?? Date.now();
      const freshMac =
        state.lastMacSeenAt !== undefined &&
        synchronizedAt - state.lastMacSeenAt <= 45_000;
      return {
        ...state,
        state: freshMac
          ? ((state.rttMs ?? 0) > 1_500 ? "slow" : "live")
          : "resyncing",
        synchronized: true,
        lastSyncAt: synchronizedAt,
        reconnectAttempt: 0,
        detail: freshMac ? undefined : "Viewport is current. Waiting for a fresh Mac health acknowledgement.",
      };
    }
    case "rotation-start":
      if (state.state === "mac-offline") {
        return {
          ...state,
          synchronized: false,
          detail: "The browser connection is rotating while the Mac remains offline.",
        };
      }
      return {
        ...state,
        state: "rotating",
        synchronized: false,
        detail: "Opening a replacement connection.",
      };
    case "delivery-uncertain":
      return { ...state, state: "delivery-uncertain", detail: action.detail };
    case "ended":
      return {
        ...state,
        state: action.revoked ? "revoked" : "remote-ended",
        socketOpen: false,
        synchronized: false,
        detail: action.revoked ? "This controller was revoked on the Mac." : "Remote Control was disabled.",
      };
    case "version-mismatch":
      return {
        ...state,
        state: "update-required",
        socketOpen: false,
        synchronized: false,
        detail: "The Mac and web protocol versions differ.",
      };
    case "simulate":
      return {
        ...state,
        state: action.state,
        socketOpen: ["live", "slow", "mac-offline", "resyncing", "delivery-uncertain"].includes(
          action.state,
        ),
        synchronized: action.state === "live" || action.state === "slow",
        rttMs: action.rttMs ?? state.rttMs,
        reconnectAttempt: action.state === "reconnecting" ? state.reconnectAttempt + 1 : 0,
        staleSince: ["phone-offline", "mac-offline", "reconnecting"].includes(action.state)
          ? Date.now()
          : state.staleSince,
        detail: action.state === "delivery-uncertain"
          ? "Request cmd_X3 may have reached the Mac."
          : undefined,
      };
    case "retry":
      return {
        ...state,
        state: "reconnecting",
        socketOpen: false,
        synchronized: false,
        reconnectAttempt: state.reconnectAttempt + 1,
      };
  }
}

export function connectionLabel(model: ConnectionModel): string {
  switch (model.state) {
    case "live":
      return "LIVE";
    case "slow":
      return `SLOW · ${model.rttMs ?? "—"}ms`;
    case "connecting":
      return "CONNECTING";
    case "reconnecting":
      return `RECONNECTING · ${model.reconnectAttempt}`;
    case "rotating":
      return "ROTATING CONNECTION";
    case "phone-offline":
      return "PHONE OFFLINE";
    case "mac-offline":
      return "MAC OFFLINE";
    case "resyncing":
      return "RESYNCING";
    case "delivery-uncertain":
      return "DELIVERY UNCERTAIN";
    case "remote-ended":
      return "REMOTE ENDED";
    case "revoked":
      return "REVOKED";
    case "update-required":
      return "UPDATE REQUIRED";
  }
}
