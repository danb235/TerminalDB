#!/usr/bin/env python3
"""Exercise the real session helper through its protected native IPC socket.

Only disposable sessions and test-owned files are used. Terminal output,
credentials and launch secrets are never printed. This supplements visible QA.
"""
import base64
import json
import os
from pathlib import Path
import socket
import struct
import subprocess
import sys
import tempfile
import time
import uuid


class Client:
    def __init__(self, root, client_id=None, peer_id=None, management=False):
        self.socket = socket.socket(socket.AF_UNIX)
        socket_name = "peer" if peer_id or management else "host"
        self.socket.connect(str(root / (socket_name + ".sock")))
        self.socket.settimeout(10)
        self.events = []
        self.session = ""
        self.generation = 0
        self.sequence = 0
        self.client_id = client_id or str(uuid.uuid4())
        self.send({"type": "hello", "version": 1,
                   "clientId": self.client_id,
                   "secret": (root / (socket_name + ".secret")).read_text()})
        ready = self.read()
        assert ready["type"] == "ready"
        if peer_id:
            self.send(dict(type="connect", peerId=peer_id))
            while not ready.get("peerConnected"):
                ready = self.read()
                if ready.get("type") == "error": raise RuntimeError("Peer connection refused")
        self.host_clock = ready.get("hostClock", 0); self.received_clock = time.monotonic()
        self.path = ready.get("connectionPath", "This Mac")

    def send(self, value):
        data = json.dumps(value).encode()
        self.socket.sendall(struct.pack(">I", len(data)) + data)

    def read(self):
        def exact(count):
            data = b""
            while len(data) < count:
                part = self.socket.recv(count - len(data))
                if not part:
                    raise RuntimeError("Helper connection ended")
                data += part
            return data
        length = struct.unpack(">I", exact(4))[0]
        assert 1 < length <= 1048576
        return json.loads(exact(length))

    def request(self, operation, request_id=None, **payload):
        request_id = request_id or str(uuid.uuid4())
        self.send(dict(type="request", requestId=request_id, operation=operation,
                       sessionId=self.session, generation=self.generation, **payload))
        while True:
            result = self.read()
            if result.get("type") == "reply" and result.get("requestId") == request_id:
                return result
            self.events.append(result)

    def attach(self, session):
        self.session = session
        result = self.request("session.attach")
        self.generation = result["generation"]
        return result

    def input(self, text, request_id=None):
        self.sequence += 1
        return self.request("terminal.input", request_id=request_id,
                            data=base64.b64encode(text.encode()).decode(),
                            inputSequence=self.sequence,
                            inputDeadline=self.host_clock + time.monotonic() - self.received_clock + 10)

    def close(self):
        self.socket.close()


def wait_for(predicate, timeout=10):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if predicate():
            return
        time.sleep(0.03)
    raise AssertionError("Disposable peer session did not reach its expected state")


def main():
    app = Path(sys.argv[1]).resolve()
    checks = 0
    with tempfile.TemporaryDirectory(prefix="tdb-peer-", dir="/tmp") as temporary:
        root = Path(temporary)
        env = dict(os.environ, TERMINALDB_PEER_STATE_DIR=str(root),
                   TERMINALDB_PEER_EPHEMERAL_IDENTITY="1")
        helper = subprocess.Popen([str(app), "--session-host", "--terminal-qa"], env=env,
                                  stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                                  stderr=subprocess.DEVNULL)
        agent = None
        clients = []
        try:
            wait_for(lambda: (root / "host.sock").exists())
            assert (root / "host.sock").stat().st_mode & 0o777 == 0o600
            checks += 1
            a = Client(root); clients.append(a)
            create_id = str(uuid.uuid4())
            created = a.request("session.create", request_id=create_id, directory=str(root))
            assert "error" not in created
            a.session = created["sessionId"]; a.generation = created["generation"]
            assert created["controlling"]
            checks += 1
            repeated = a.request("session.create", request_id=create_id, directory=str(root))
            assert repeated["sessionId"] == a.session
            assert len(a.request("session.list")["sessions"]) == 1
            checks += 1
            expired = a.request("terminal.input", data=base64.b64encode(b"forbidden\r").decode(),
                                inputSequence=1, inputDeadline=a.host_clock - 1)
            assert expired.get("code") == "input-expired"
            assert a.input("forbidden\r").get("code") == "input-blocked"
            original_session, original_client = a.session, a.client_id
            a.close(); clients.remove(a)
            a = Client(root, client_id=original_client); clients.append(a)
            a.attach(original_session)
            checks += 1
            assert a.request("workspace.restoreSession", snapshot={"chat_messages": [{"role": "user", "content": "Synthetic saved conversation"}]}).get("accepted")
            assert a.request("host.state")["assistant"]["messages"][0]["content"] == "Synthetic saved conversation"
            checks += 1
            assert a.input("printf '%s' $$ > first-shell-id\r").get("accepted")
            wait_for(lambda: (root / "first-shell-id").exists())
            checks += 1
            b = Client(root); clients.append(b)
            assert not b.attach(a.session)["controlling"]
            assert b.request("project.inspect", command="printf forbidden > must-not-exist").get("code") == "control-required"
            assert b.input("printf forbidden > must-not-exist\r").get("code") == "control-required"
            assert not (root / "must-not-exist").exists()
            checks += 1
            b.generation = b.request("control.acquire")["generation"]
            assert a.input("printf forbidden > stale-writer\r").get("code") == "control-required"
            assert not (root / "stale-writer").exists()
            checks += 1
            b.sequence = 0  # rejected input never entered this stream
            assert b.input("printf '%s' $$ > second-shell-id\r").get("accepted")
            wait_for(lambda: (root / "second-shell-id").exists())
            assert (root / "first-shell-id").read_text() == (root / "second-shell-id").read_text()
            checks += 1
            assert "error" in b.request("terminal.resize", columns=0, rows=0)
            assert b.request("terminal.resize", columns=100, rows=30).get("accepted")
            checks += 1
            wait_for(lambda: not b.request("host.state")["busy"])
            approval = b.request("execution.prepare", command="printf approved > approved-marker")
            assert approval.get("approval")
            a.generation = a.request("control.acquire")["generation"]
            b.generation = b.request("control.acquire")["generation"]
            assert "error" in b.request("execution.commit", approval=approval["approval"])
            assert not (root / "approved-marker").exists()
            checks += 1
            assert b.input("/bin/sleep 1; printf survived > disconnect-marker\r").get("accepted")
            b.close(); clients.remove(b)
            wait_for(lambda: (root / "disconnect-marker").exists())
            c = Client(root); clients.append(c)
            assert c.attach(a.session)["controlling"]
            assert c.input("printf '%s' $$ > third-shell-id\r").get("accepted")
            wait_for(lambda: (root / "third-shell-id").exists())
            assert (root / "first-shell-id").read_text() == (root / "third-shell-id").read_text()
            checks += 1
            reservation = socket.socket(); reservation.bind(("127.0.0.1", 0))
            port = reservation.getsockname()[1]; reservation.close()
            (root / "trust.json").write_text(json.dumps(dict(peers={}, listenPort=port,
                allowForwarding=False, publicEndpoints=[])))
            agent = subprocess.Popen([str(app), "--peer-agent"], env=env,
                stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            wait_for(lambda: (root / "peer.sock").exists())
            agent.terminate(); agent.wait(timeout=10); agent = None
            assert helper.poll() is None
            assert c.input("printf '%s' $$ > fourth-shell-id\r").get("accepted")
            wait_for(lambda: (root / "fourth-shell-id").exists())
            assert (root / "first-shell-id").read_text() == (root / "fourth-shell-id").read_text()
            checks += 1
            d = Client(root, client_id=c.client_id); clients.append(d)
            assert d.attach(a.session)["controlling"]
            c.close(); clients.remove(c)
            assert d.input("printf fenced > reconnect-marker\r").get("accepted")
            wait_for(lambda: (root / "reconnect-marker").exists())
            checks += 1
            assert d.request("session.end").get("accepted")
            assert not d.request("session.list")["sessions"]
            checks += 1
            e = Client(root); clients.append(e)
            created = e.request("session.create", directory=str(root), private=True)
            e.session = created["sessionId"]; e.generation = created["generation"]
            assert e.input("printf 'QA_SYNTHETIC_界\\n'; exit\r").get("accepted")
            wait_for(lambda: not e.request("session.list")["sessions"])
            output = b"".join(base64.b64decode(event["data"]) for event in e.events if event.get("type") == "output")
            assert "QA_SYNTHETIC_界".encode() in output
            assert any(event.get("type") == "ended" and event.get("sessionId") == e.session for event in e.events)
            checks += 1
            print(f"TerminalDB persistent session integration checks: {checks} passed")
        finally:
            for client in clients:
                client.close()
            for process in [agent, helper]:
                if process and process.poll() is None:
                    process.terminate()
                    try:
                        process.wait(timeout=10)
                    except subprocess.TimeoutExpired:
                        process.kill(); process.wait()
                if process:
                    subprocess.run(["defaults", "delete", "com.terminaldb.qa." + str(process.pid)], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


if __name__ == "__main__":
    main()
