import React from "react";

interface AppErrorBoundaryState {
  readonly failed: boolean;
}

interface AppErrorBoundaryProps {
  readonly children?: React.ReactNode;
}

export class AppErrorBoundary extends React.Component<AppErrorBoundaryProps, AppErrorBoundaryState> {
  override state: AppErrorBoundaryState = { failed: false };

  static getDerivedStateFromError(): AppErrorBoundaryState {
    return { failed: true };
  }

  override componentDidCatch(error: Error): void {
    console.error("TerminalDB Remote could not render", error);
  }

  override render(): React.ReactNode {
    if (!this.state.failed) return this.props.children;
    return (
      <main className="app-recovery" role="alert">
        <section>
          <div className="app-recovery-mark" aria-hidden="true">&gt;_</div>
          <span>TERMINALDB REMOTE</span>
          <h1>TerminalDB needs a fresh start</h1>
          <p>Your account and terminal sessions are safe. Reload to fetch the current web app.</p>
          <button onClick={() => location.reload()}>Reload TerminalDB</button>
        </section>
      </main>
    );
  }
}
