import { FitAddon } from "@xterm/addon-fit";
import { Terminal } from "@xterm/xterm";
import type { RemoteInputMode } from "@terminaldb/protocol";
import {
  forwardRef,
  useEffect,
  useImperativeHandle,
  useRef,
} from "react";

import { adaptSnapshotToLocalViewport } from "./terminal-viewport";
import {
  optimisticRenderForInput,
  reconcileOptimisticEcho,
} from "./optimistic-input";
import type { SequencedInputBatch } from "./ordered-input";

export interface TerminalUpdate {
  readonly id: number;
  readonly text: string;
  readonly viewport: boolean;
  readonly rows: number;
  readonly columns: number;
  readonly inputMode: RemoteInputMode;
  readonly inputStreamId?: string;
  readonly inputThrough?: number;
}

export interface TerminalSurfaceHandle {
  readonly focus: () => void;
  readonly getSelection: () => string;
  readonly getViewportText: () => string;
  readonly scrollToBottom: () => void;
  readonly markOptimisticInputSent: (batch: SequencedInputBatch) => void;
  readonly confirmOptimisticInput: (committed?: boolean) => void;
  readonly rollbackOptimisticInput: () => void;
}

interface TerminalSurfaceProps {
  readonly update: TerminalUpdate;
  readonly active: boolean;
  readonly followOutput: boolean;
  readonly inputEnabled: boolean;
  readonly onInput: (data: string) => void;
  readonly onGeometryChange: (columns: number, rows: number) => void;
  readonly onFollowOutputChange: (following: boolean) => void;
  readonly onSelectionChange: (hasSelection: boolean) => void;
  readonly onAuthoritativeRefreshNeeded: () => void;
}

interface OptimisticState {
  readonly mode: Exclude<RemoteInputMode, "secure">;
  readonly expectedEcho: string;
}

interface ApplicationOverlayAnchor {
  readonly column: number;
  readonly row: number;
}

interface ViewportAnchor {
  readonly line: string;
  readonly viewportY: number;
  readonly distanceFromBottom: number;
  readonly selection?: {
    readonly column: number;
    readonly row: number;
    readonly length: number;
  };
}

const BASE_FONT_SIZE = 13.5;
const BASE_LINE_HEIGHT = 1.24;

function captureViewportAnchor(instance: Terminal): ViewportAnchor {
  const buffer = instance.buffer.active;
  const selection = instance.getSelectionPosition();
  return {
    line: buffer.getLine(buffer.viewportY)?.translateToString(true) ?? "",
    viewportY: buffer.viewportY,
    distanceFromBottom: Math.max(0, buffer.baseY - buffer.viewportY),
    ...(selection ? {
      selection: {
        column: selection.start.x,
        row: selection.start.y,
        length: instance.getSelection().length,
      },
    } : {}),
  };
}

function restoreViewportAnchor(instance: Terminal, anchor: ViewportAnchor): void {
  const buffer = instance.buffer.active;
  let restoredViewportY: number | undefined;
  if (anchor.line) {
    for (let line = buffer.baseY; line >= 0; line -= 1) {
      if (buffer.getLine(line)?.translateToString(true) === anchor.line) {
        instance.scrollToLine(line);
        restoredViewportY = line;
        break;
      }
    }
  }
  if (restoredViewportY === undefined) {
    restoredViewportY = Math.max(0, buffer.baseY - anchor.distanceFromBottom);
    instance.scrollToLine(restoredViewportY);
  }
  if (anchor.selection && anchor.selection.length > 0) {
    const rowOffset = restoredViewportY - anchor.viewportY;
    instance.select(
      anchor.selection.column,
      Math.max(0, anchor.selection.row + rowOffset),
      anchor.selection.length,
    );
  }
}

export const TerminalSurface = forwardRef<
  TerminalSurfaceHandle,
  TerminalSurfaceProps
>(function TerminalSurface(
  {
    update,
    active,
    followOutput,
    inputEnabled,
    onInput,
    onGeometryChange,
    onFollowOutputChange,
    onSelectionChange,
    onAuthoritativeRefreshNeeded,
  },
  forwardedRef,
) {
  const host = useRef<HTMLDivElement>(null);
  const optimisticOverlay = useRef<HTMLDivElement>(null);
  const terminal = useRef<Terminal | null>(null);
  const fitAddon = useRef<FitAddon | null>(null);
  const renderedUpdate = useRef(-1);
  const lastViewportText = useRef<string | undefined>(undefined);
  const inputHandler = useRef(onInput);
  const followHandler = useRef(onFollowOutputChange);
  const selectionHandler = useRef(onSelectionChange);
  const geometryHandler = useRef(onGeometryChange);
  const applyingUpdate = useRef(false);
  const suppressNativeControlC = useRef(false);
  const inputEnabledRef = useRef(inputEnabled);
  const inputModeRef = useRef(update.inputMode);
  const refreshHandler = useRef(onAuthoritativeRefreshNeeded);
  const optimistic = useRef<OptimisticState | undefined>(undefined);
  const applicationDraft = useRef("");
  const applicationAnchor = useRef<ApplicationOverlayAnchor | undefined>(undefined);
  const applicationUnsequencedInput = useRef("");
  const applicationInputStream = useRef<string | undefined>(undefined);
  const applicationHighestSequence = useRef(0);
  const editableCells = useRef(0);
  const authoritativeViewport = useRef<TerminalUpdate | undefined>(undefined);
  const authoritativeIncremental = useRef<string[]>([]);
  const authoritativeIncrementalLength = useRef(0);
  const authoritativeReplayAvailable = useRef(true);
  const rebuildAuthoritativeRef = useRef<() => void>(() => undefined);
  const applicationRefreshTimer = useRef<number | undefined>(undefined);

  inputHandler.current = onInput;
  followHandler.current = onFollowOutputChange;
  selectionHandler.current = onSelectionChange;
  geometryHandler.current = onGeometryChange;
  inputEnabledRef.current = inputEnabled;
  inputModeRef.current = update.inputMode;
  refreshHandler.current = onAuthoritativeRefreshNeeded;

  const paintApplicationOverlay = () => {
    const overlay = optimisticOverlay.current;
    const instance = terminal.current;
    const scrollplane = host.current?.parentElement;
    if (!overlay || !instance || !scrollplane || !applicationDraft.current) {
      if (overlay) {
        overlay.hidden = true;
        overlay.replaceChildren();
      }
      return;
    }
    const screen = host.current?.querySelector<HTMLElement>(".xterm-screen");
    if (!screen) {
      overlay.hidden = true;
      return;
    }
    const anchor = applicationAnchor.current ?? {
      column: instance.buffer.active.cursorX,
      row: instance.buffer.active.cursorY,
    };
    applicationAnchor.current = anchor;
    const screenBounds = screen.getBoundingClientRect();
    const scrollplaneBounds = scrollplane.getBoundingClientRect();
    const cellWidth = screenBounds.width / Math.max(1, instance.cols);
    const cellHeight = screenBounds.height / Math.max(1, instance.rows);
    overlay.style.left = `${screenBounds.left - scrollplaneBounds.left}px`;
    overlay.style.top = `${screenBounds.top - scrollplaneBounds.top + anchor.row * cellHeight}px`;
    overlay.style.width = `${screenBounds.width}px`;
    overlay.style.maxHeight = `${Math.max(
      cellHeight,
      (instance.rows - anchor.row) * cellHeight,
    )}px`;
    const characters = Array.from(applicationDraft.current);
    const rows: HTMLSpanElement[] = [];
    let offset = 0;
    let column = anchor.column;
    while (offset < characters.length) {
      const available = Math.max(1, instance.cols - column);
      const row = document.createElement("span");
      row.className = "optimistic-input-row";
      row.style.marginLeft = `${column * cellWidth}px`;
      row.style.height = `${cellHeight}px`;
      row.style.lineHeight = `${cellHeight}px`;
      row.textContent = characters.slice(offset, offset + available).join("");
      rows.push(row);
      offset += available;
      column = 0;
    }
    rows.at(-1)?.classList.add("has-cursor");
    overlay.replaceChildren(...rows);
    overlay.hidden = false;
  };

  const resetApplicationPrediction = () => {
    applicationDraft.current = "";
    applicationAnchor.current = undefined;
    applicationUnsequencedInput.current = "";
    applicationInputStream.current = undefined;
    applicationHighestSequence.current = 0;
    paintApplicationOverlay();
  };

  const updateOptimisticMetadata = (state = optimistic.current) => {
    if (!host.current) return;
    host.current.dataset.inputMode = inputModeRef.current;
    host.current.dataset.optimisticPending = state
      ? String(state.expectedEcho.length || 1)
      : "0";
    host.current.dataset.editableCells = String(editableCells.current);
  };

  const clearOptimisticInput = (resetEditableCells = false) => {
    optimistic.current = undefined;
    resetApplicationPrediction();
    if (resetEditableCells) editableCells.current = 0;
    updateOptimisticMetadata(undefined);
  };

  const scheduleApplicationRefresh = (committed = false) => {
    if (optimistic.current?.mode !== "application") return;
    if (applicationRefreshTimer.current !== undefined) {
      window.clearTimeout(applicationRefreshTimer.current);
    }
    applicationRefreshTimer.current = window.setTimeout(() => {
      applicationRefreshTimer.current = undefined;
      if (optimistic.current?.mode === "application") {
        refreshHandler.current();
      }
    }, committed ? 300 : 600);
  };

  useImperativeHandle(forwardedRef, () => ({
    focus: () => terminal.current?.focus(),
    getSelection: () => terminal.current?.getSelection() ?? "",
    getViewportText: () => {
      const instance = terminal.current;
      if (!instance) return "";
      const buffer = instance.buffer.active;
      const lines: string[] = [];
      const lastLine = Math.min(buffer.length - 1, buffer.viewportY + instance.rows - 1);
      for (let line = buffer.viewportY; line <= lastLine; line += 1) {
        lines.push(buffer.getLine(line)?.translateToString(true) ?? "");
      }
      return lines.join("\n");
    },
    scrollToBottom: () => terminal.current?.scrollToBottom(),
    markOptimisticInputSent: (batch) => {
      if (optimistic.current?.mode !== "application") return;
      if (applicationUnsequencedInput.current.startsWith(batch.input)) {
        applicationUnsequencedInput.current =
          applicationUnsequencedInput.current.slice(batch.input.length);
      } else if (batch.input.startsWith(applicationUnsequencedInput.current)) {
        applicationUnsequencedInput.current = "";
      }
      applicationInputStream.current = batch.inputStreamId;
      applicationHighestSequence.current = Math.max(
        applicationHighestSequence.current,
        batch.inputSequence,
      );
      updateOptimisticMetadata();
    },
    confirmOptimisticInput: scheduleApplicationRefresh,
    rollbackOptimisticInput: () => {
      if (!optimistic.current) return;
      clearOptimisticInput(true);
      rebuildAuthoritativeRef.current();
    },
  }), []);

  useEffect(() => {
    if (!host.current) return;
    const hostElement = host.current;
    // React StrictMode intentionally remounts effects in development. Reset
    // renderer bookkeeping so the replacement xterm receives the current
    // Mac snapshot instead of inheriting the disposed instance's update id.
    renderedUpdate.current = -1;
    lastViewportText.current = undefined;
    authoritativeViewport.current = undefined;
    authoritativeIncremental.current = [];
    authoritativeIncrementalLength.current = 0;
    authoritativeReplayAvailable.current = true;
    optimistic.current = undefined;
    resetApplicationPrediction();
    editableCells.current = 0;
    const instance = new Terminal({
      allowProposedApi: false,
      convertEol: true,
      cursorBlink: true,
      disableStdin: !inputEnabled,
      fontFamily: '"JetBrains Mono", "SFMono-Regular", monospace',
      fontSize: BASE_FONT_SIZE,
      lineHeight: BASE_LINE_HEIGHT,
      minimumContrastRatio: 1,
      scrollback: 10_000,
      smoothScrollDuration: 0,
      theme: {
        background: "#17171A",
        foreground: "#E7E7E2",
        cursor: "#E7E7E2",
        cursorAccent: "#17171A",
        selectionBackground: "#52D0DD2E",
        black: "#101013",
        red: "#EF6557",
        green: "#B4E34D",
        yellow: "#E3AC4E",
        blue: "#D88A55",
        magenta: "#A78BD4",
        cyan: "#52D0DD",
        white: "#E7E7E2",
        brightBlack: "#6B6B66",
        brightRed: "#FF858A",
        brightGreen: "#C7F062",
        brightYellow: "#F0C66B",
        brightBlue: "#E29B68",
        brightMagenta: "#B9A0E8",
        brightCyan: "#72E2EC",
        brightWhite: "#F3F6F7",
      },
    });
    const fitting = new FitAddon();
    instance.loadAddon(fitting);
    instance.open(hostElement);
    fitting.fit();
    updateOptimisticMetadata();
    const interceptControlC = (event: KeyboardEvent) => {
      if (
        event.key.toLowerCase() !== "c" ||
        !event.ctrlKey ||
        event.metaKey ||
        event.altKey
      ) return;
      event.preventDefault();
      event.stopPropagation();
      if (event.shiftKey && instance.hasSelection()) {
        void navigator.clipboard.writeText(instance.getSelection());
      } else {
        suppressNativeControlC.current = true;
        inputHandler.current("\u0003");
        window.setTimeout(() => {
          suppressNativeControlC.current = false;
        }, 0);
      }
    };
    hostElement.addEventListener("keydown", interceptControlC, true);
    const focusFromEmptySpace = (event: PointerEvent) => {
      if (event.target === hostElement && inputEnabledRef.current) {
        instance.focus();
      }
    };
    const scrollFromEmptySpace = (event: WheelEvent) => {
      if (event.target !== hostElement) return;
      const lines = Math.sign(event.deltaY) * Math.max(1, Math.round(Math.abs(event.deltaY) / 36));
      instance.scrollLines(lines);
    };
    hostElement.addEventListener("pointerdown", focusFromEmptySpace);
    hostElement.addEventListener("wheel", scrollFromEmptySpace, { passive: true });
    const inputSubscription = instance.onData((data) => {
      if (data === "\u0003" && suppressNativeControlC.current) {
        suppressNativeControlC.current = false;
        return;
      }
      const applicationMode = inputModeRef.current === "application";
      let applicationSafe = applicationMode && data.length > 0;
      if (applicationSafe) {
        if (!applicationAnchor.current) {
          applicationAnchor.current = {
            column: instance.buffer.active.cursorX,
            row: instance.buffer.active.cursorY,
          };
        }
        let nextDraft = applicationDraft.current;
        for (const character of data) {
          const codePoint = character.codePointAt(0);
          if (codePoint !== undefined && codePoint >= 0x20 && codePoint !== 0x7f) {
            nextDraft += character;
          } else if (character === "\b" || character === "\x7f") {
            nextDraft = Array.from(nextDraft).slice(0, -1).join("");
          } else if (character === "\r") {
            nextDraft = "";
            applicationAnchor.current = undefined;
          } else {
            applicationSafe = false;
            break;
          }
        }
        if (applicationSafe) {
          applicationDraft.current = nextDraft;
          editableCells.current = Array.from(nextDraft).length;
          applicationUnsequencedInput.current += data;
          optimistic.current = {
            mode: "application",
            expectedEcho: "",
          };
          instance.scrollToBottom();
          followHandler.current(true);
          paintApplicationOverlay();
          updateOptimisticMetadata();
        } else if (optimistic.current?.mode === "application") {
          clearOptimisticInput(true);
          rebuildAuthoritativeRef.current();
        }
      }
      const speculative = applicationMode
        ? undefined
        : optimisticRenderForInput(
            data,
            inputModeRef.current,
            editableCells.current,
          );
      if (speculative) {
        editableCells.current = speculative.editableCells;
        updateOptimisticMetadata();
      } else if (/[\r\n\u0003\u001b]/u.test(data)) {
        editableCells.current = 0;
        updateOptimisticMetadata();
      }
      if (
        !applicationMode &&
        speculative &&
        speculative.rendered &&
        authoritativeReplayAvailable.current &&
        inputEnabledRef.current
      ) {
        const existing = optimistic.current;
        if (!existing || existing.mode === inputModeRef.current) {
          optimistic.current = {
            mode: inputModeRef.current as Exclude<RemoteInputMode, "secure">,
            expectedEcho: `${existing?.expectedEcho ?? ""}${speculative.expectedEcho}`,
          };
          instance.scrollToBottom();
          followHandler.current(true);
          instance.write(speculative.rendered);
          updateOptimisticMetadata();
        }
      }
      inputHandler.current(data);
    });
    const scrollSubscription = instance.onScroll((viewportLine) => {
      if (applyingUpdate.current) return;
      followHandler.current(viewportLine >= instance.buffer.active.baseY);
    });
    const selectionSubscription = instance.onSelectionChange(() => {
      selectionHandler.current(instance.hasSelection());
    });
    terminal.current = instance;
    fitAddon.current = fitting;
    return () => {
      inputSubscription.dispose();
      scrollSubscription.dispose();
      selectionSubscription.dispose();
      hostElement.removeEventListener("keydown", interceptControlC, true);
      hostElement.removeEventListener("pointerdown", focusFromEmptySpace);
      hostElement.removeEventListener("wheel", scrollFromEmptySpace);
      instance.dispose();
      terminal.current = null;
      fitAddon.current = null;
      if (applicationRefreshTimer.current !== undefined) {
        window.clearTimeout(applicationRefreshTimer.current);
        applicationRefreshTimer.current = undefined;
      }
    };
  }, []);

  useEffect(() => {
    const instance = terminal.current;
    const element = host.current;
    const fitting = fitAddon.current;
    if (!instance || !element || !fitting) return;
    let animationFrame: number | undefined;
    const applyGeometry = () => {
      if (animationFrame !== undefined) window.cancelAnimationFrame(animationFrame);
      animationFrame = window.requestAnimationFrame(() => {
        animationFrame = undefined;
        const previousColumns = instance.cols;
        const previousRows = instance.rows;
        fitting.fit();
        element.dataset.fontSize = String(BASE_FONT_SIZE);
        element.dataset.columns = String(instance.cols);
        element.dataset.rows = String(instance.rows);
        if (
          renderedUpdate.current >= 0 &&
          inputModeRef.current === "application" &&
          (previousColumns !== instance.cols || previousRows !== instance.rows)
        ) {
          // A full-screen TUI is a fixed cell grid. Never let xterm reflow an
          // old Claude frame into a new browser width; wait for the Mac PTY to
          // redraw at the controller's geometry instead.
          element.dataset.geometrySync = "pending";
          applyingUpdate.current = true;
          instance.reset();
          applyingUpdate.current = false;
        }
        geometryHandler.current(instance.cols, instance.rows);
      });
    };
    applyGeometry();
    const observer = new ResizeObserver(applyGeometry);
    observer.observe(element);
    return () => {
      observer.disconnect();
      if (animationFrame !== undefined) window.cancelAnimationFrame(animationFrame);
    };
  }, []);

  useEffect(() => {
    const instance = terminal.current;
    if (!instance) return;
    instance.options.disableStdin = !inputEnabled;
    if (!inputEnabled) {
      instance.blur();
      editableCells.current = 0;
      updateOptimisticMetadata();
      if (optimistic.current) {
        clearOptimisticInput(true);
        rebuildAuthoritativeRef.current();
      }
    }
  }, [inputEnabled]);

  useEffect(() => {
    updateOptimisticMetadata();
    if (update.inputMode === "secure") {
      editableCells.current = 0;
      updateOptimisticMetadata();
      if (optimistic.current) {
        clearOptimisticInput(true);
        rebuildAuthoritativeRef.current();
      }
    }
  }, [update.inputMode]);

  useEffect(() => {
    if (!active) return;
    if (window.matchMedia("(pointer: fine)").matches && inputEnabled) {
      terminal.current?.focus();
    }
  }, [active, inputEnabled]);

  useEffect(() => {
    if (followOutput) terminal.current?.scrollToBottom();
  }, [followOutput]);

  useEffect(() => {
    const instance = terminal.current;
    if (!instance || update.id === renderedUpdate.current) return;
    const element = host.current;
    const applicationGeometryMismatch =
      update.viewport &&
      update.inputMode === "application" &&
      (update.rows !== instance.rows || update.columns !== instance.cols);
    if (applicationGeometryMismatch) {
      if (element) element.dataset.geometrySync = "pending";
      renderedUpdate.current = update.id;
      refreshHandler.current();
      return;
    }
    if (
      element &&
      update.rows === instance.rows &&
      update.columns === instance.cols
    ) {
      element.dataset.geometrySync = "ready";
    }
    const anchor = captureViewportAnchor(instance);
    const confirmsApplicationPrediction =
      optimistic.current?.mode === "application" &&
      applicationUnsequencedInput.current.length === 0 &&
      applicationHighestSequence.current > 0 &&
      update.inputStreamId === applicationInputStream.current &&
      (update.inputThrough ?? 0) >= applicationHighestSequence.current;
    const rebuildAuthoritative = () => {
      if (!authoritativeReplayAvailable.current) {
        refreshHandler.current();
        return;
      }
      const viewport = authoritativeViewport.current;
      const chunks: string[] = [];
      if (viewport) {
        chunks.push(adaptSnapshotToLocalViewport(
          viewport.text,
          viewport.rows,
          instance.rows,
          instance.cols,
        ));
      }
      chunks.push(...authoritativeIncremental.current);
      applyingUpdate.current = true;
      instance.reset();
      instance.write(chunks.join(""), () => {
        if (terminal.current !== instance) return;
        if (followOutput) instance.scrollToBottom();
        else restoreViewportAnchor(instance, anchor);
        applyingUpdate.current = false;
      });
    };
    rebuildAuthoritativeRef.current = rebuildAuthoritative;

    const hasOptimisticInput = optimistic.current !== undefined;
    const isDuplicateViewport =
      update.viewport &&
      !hasOptimisticInput &&
      lastViewportText.current === update.text &&
      authoritativeViewport.current?.rows === update.rows &&
      authoritativeViewport.current?.columns === update.columns;
    if (isDuplicateViewport) {
      authoritativeViewport.current = update;
      renderedUpdate.current = update.id;
      updateOptimisticMetadata();
      return;
    }

    if (update.viewport) {
      authoritativeViewport.current = update;
      authoritativeIncremental.current = [];
      authoritativeIncrementalLength.current = 0;
      authoritativeReplayAvailable.current = true;
      lastViewportText.current = update.text;
      if (optimistic.current?.mode !== "application") {
        clearOptimisticInput();
      }
      applyingUpdate.current = true;
      instance.reset();
    } else {
      authoritativeIncremental.current.push(update.text);
      authoritativeIncrementalLength.current += update.text.length;
      if (authoritativeIncrementalLength.current > 1_000_000) {
        authoritativeReplayAvailable.current = false;
        clearOptimisticInput(true);
        refreshHandler.current();
      }
    }

    let renderedText = update.viewport
      ? adaptSnapshotToLocalViewport(
        update.text,
        update.rows,
        instance.rows,
        instance.cols,
      )
      : update.text;

    const pending = optimistic.current;
    if (!update.viewport && pending) {
      if (update.inputMode === "secure") {
        clearOptimisticInput(true);
        rebuildAuthoritative();
        renderedUpdate.current = update.id;
        return;
      }
      if (pending.mode === "application") {
        if (update.inputMode !== "application") {
          clearOptimisticInput(true);
          rebuildAuthoritative();
          renderedUpdate.current = update.id;
          return;
        }
      } else {
        const reconciled = reconcileOptimisticEcho(
          pending.expectedEcho,
          update.text,
        );
        if (reconciled.mismatch) {
          clearOptimisticInput(true);
          rebuildAuthoritative();
          refreshHandler.current();
          renderedUpdate.current = update.id;
          return;
        }
        optimistic.current = reconciled.expectedEcho
          ? { ...pending, expectedEcho: reconciled.expectedEcho }
          : undefined;
        updateOptimisticMetadata();
        renderedText = reconciled.output;
      }
    }

    applyingUpdate.current = true;
    instance.write(renderedText, () => {
      if (terminal.current !== instance) return;
      if (followOutput) {
        instance.scrollToBottom();
      } else if (update.viewport) {
        restoreViewportAnchor(instance, anchor);
      }
      if (confirmsApplicationPrediction) {
        clearOptimisticInput(true);
      } else if (optimistic.current?.mode === "application") {
        paintApplicationOverlay();
      }
      applyingUpdate.current = false;
    });
    renderedUpdate.current = update.id;
  }, [followOutput, update]);

  return (
    <div
      className={`terminal-pane ${active ? "active" : ""}`}
      aria-hidden={!active}
    >
      <div className="terminal-scrollplane">
        <div
          ref={host}
          className="xterm-host"
          aria-label={inputEnabled
            ? "Remote terminal. Type commands here."
            : "Remote terminal output. Input unavailable."}
          aria-disabled={!inputEnabled}
        />
        <div
          ref={optimisticOverlay}
          className="optimistic-input-overlay"
          aria-hidden="true"
          hidden
        />
      </div>
    </div>
  );
});
