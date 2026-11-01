#!/usr/bin/env python3
"""Real agent + host pairing and private-network checks using disposable native peers.

Requires Bonjour/Local Network permission. Supplements physical visible QA;
never prints identities, launch secrets or terminal payloads.
"""
import importlib.util
import json
import os
from pathlib import Path
import socket
import subprocess
import sys
import tempfile
import uuid

spec = importlib.util.spec_from_file_location("session_qa", Path(__file__).with_name("peer-session-qa.py"))
qa = importlib.util.module_from_spec(spec)
spec.loader.exec_module(qa)
Client, wait_for = qa.Client, qa.wait_for


def main():
    app = Path(sys.argv[1]).resolve()
    processes, clients = [], []
    checks = 0
    with tempfile.TemporaryDirectory(prefix="tdb-net-", dir="/tmp") as directory:
        roots = [Path(directory) / name for name in ["a", "b"]]
        try:
            for root in roots:
                root.mkdir(mode=0o700)
                reservation = socket.socket(); reservation.bind(("127.0.0.1", 0))
                port = reservation.getsockname()[1]; reservation.close()
                config = root / "trust.json"
                config.write_text(json.dumps(dict(peers={}, listenPort=port)))
                config.chmod(0o600)
                env = dict(os.environ, TERMINALDB_PEER_STATE_DIR=str(root), TERMINALDB_PEER_EPHEMERAL_IDENTITY="1")
                for role in ["--session-host", "--peer-agent"]:
                    executable = qa.helper_executable(app, "TerminalDBSessionHost" if role == "--session-host" else "TerminalDBPeerAgent")
                    processes.append(subprocess.Popen([str(executable), "--terminal-qa"], env=env,
                        stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL))
                wait_for(lambda: (root / "peer.sock").exists() and (root / "host.sock").exists())
            managers = [Client(root, management=True) for root in roots]; clients += managers
            def state(i): return managers[i].request("peers.state")
            fingerprints = [state(i)["fingerprint"] for i in range(2)]
            wait_for(lambda: all(any(item["service"] == "tdb-" + fingerprints[1-i][:12]
                                     for item in state(i)["nearby"]) for i in range(2)), timeout=20)
            checks += 1
            def discovered(i):
                return next((item for item in state(i)["nearby"] if item["service"] == "tdb-" + fingerprints[1-i][:12]), {"pairingReady": False, "name": "Nearby Mac"})
            assert all(not discovered(i)["pairingReady"] and discovered(i)["name"] == "Nearby Mac" for i in range(2))
            checks += 1
            for manager in managers: assert "error" not in manager.request("peers.pairing.open")
            wait_for(lambda: all(discovered(i)["pairingReady"] and discovered(i)["name"] != "Nearby Mac" for i in range(2)))
            checks += 1
            assert "error" not in managers[0].request("peers.pair", service="tdb-"+fingerprints[1][:12])
            wait_for(lambda: all(state(i)["candidates"] and state(i)["candidates"][0].get("ready") for i in range(2)))
            checks += 1
            candidates = [state(i)["candidates"][0] for i in range(2)]
            assert all(candidates[i]["fingerprint"] == fingerprints[1-i] for i in range(2))
            assert "error" in managers[0].request("peers.approve", candidate=candidates[0]["id"], fingerprint="0"*64)
            checks += 1
            try:
                unauthorized = Client(roots[0], peer_id=fingerprints[1]); clients.append(unauthorized)
            except (RuntimeError, OSError): pass
            else: raise AssertionError("Unpaired access was accepted")
            checks += 1
            assert "error" not in managers[0].request("peers.approve", candidate=candidates[0]["id"], fingerprint=fingerprints[1])
            assert not state(0)["peers"] and not state(1)["peers"]
            checks += 1
            assert "error" not in managers[1].request("peers.approve", candidate=candidates[1]["id"], fingerprint=fingerprints[0])
            wait_for(lambda: all(state(i)["peers"] for i in range(2)))
            for manager in managers: manager.request("peers.pairing.close")
            checks += 1
            wait_for(lambda: all(not discovered(i)["pairingReady"] and discovered(i)["name"] == "Nearby Mac" for i in range(2)))
            checks += 1
            assert "error" in managers[0].request("peers.endpoint", peerId=fingerprints[1], address="203.0.113.10:49377")
            assert "error" in managers[0].request("peers.forwarding", enabled=True)
            assert "error" in managers[0].request("peers.publicEndpoint", address="203.0.113.10:49377")
            checks += 1
            target_port = state(1)["port"]
            assert "error" not in managers[0].request("peers.endpoint", peerId=fingerprints[1], address=f"localhost:{target_port}")
            assert managers[0].request("peers.testAddress", peerId=fingerprints[1]).get("testResult")
            assert "publicAddress" not in state(0) and "forwarding" not in state(0)
            checks += 1
            remote = Client(roots[0], peer_id=fingerprints[1]); clients.append(remote)
            assert remote.path == "Direct LAN"
            created = remote.request("session.create", directory=str(roots[1]), private=True)
            assert "error" not in created
            remote.session = created["sessionId"]; remote.generation = created["generation"]
            assert remote.input("printf '%s' $$ > network-shell-id\r").get("accepted")
            wait_for(lambda: (roots[1]/"network-shell-id").exists())
            assert not (roots[0]/"network-shell-id").exists()
            checks += 1
            observer = Client(roots[1]); clients.append(observer)
            assert not observer.attach(remote.session)["controlling"]
            assert observer.input("printf forbidden > forbidden\r").get("code") == "control-required"
            checks += 1
            observer.generation = observer.request("control.acquire")["generation"]
            assert remote.input("printf forbidden > forbidden\r").get("code") == "control-required"
            assert not (roots[1]/"forbidden").exists()
            checks += 1
            observer.request("product.invoke", action="runbook.save", name="Synthetic QA", command="pwd")
            assert observer.request("product.list", kind="runbooks")["items"][0]["name"] == "Synthetic QA"
            assert observer.request("project.files").get("items")
            checks += 1
            remote.close(); clients.remove(remote)
            remote = Client(roots[0], peer_id=fingerprints[1]); clients.append(remote)
            assert not remote.attach(observer.session)["controlling"]
            assert remote.request("host.state")["sessionId"] == observer.session
            checks += 1
            assert "error" not in managers[1].request("peers.remove", peerId=fingerprints[0])
            try:
                remote.request("session.list")
            except (RuntimeError, OSError): pass
            else: raise AssertionError("Revoked connection stayed open")
            assert observer.request("session.end").get("accepted")
            checks += 1
            assert "error" not in managers[0].request("peers.remove", peerId=fingerprints[1])
            # Both people may select the other Mac at the same time. Their
            # approvals must converge on one connection, without trust shortcuts.
            from concurrent.futures import ThreadPoolExecutor
            import threading
            for _ in range(3):
                for manager in managers: manager.request("peers.pairing.open")
                wait_for(lambda: all(discovered(i)["pairingReady"] for i in range(2)))
                barrier = threading.Barrier(2)
                def start_pairing(i):
                    barrier.wait()
                    return managers[i].request("peers.pair", service="tdb-"+fingerprints[1-i][:12])
                with ThreadPoolExecutor(max_workers=2) as pool:
                    results = list(pool.map(start_pairing, range(2)))
                assert all("error" not in result for result in results)
                wait_for(lambda: all(len(state(i)["candidates"]) == 1 and state(i)["candidates"][0]["ready"] for i in range(2)))
                for i in range(2):
                    candidate = state(i)["candidates"][0]
                    assert candidate["fingerprint"] == fingerprints[1-i]
                    assert "error" not in managers[i].request("peers.approve", candidate=candidate["id"], fingerprint=fingerprints[1-i])
                wait_for(lambda: all(state(i)["peers"] for i in range(2)))
                for i in range(2):
                    managers[i].request("peers.pairing.close")
                    managers[i].request("peers.remove", peerId=fingerprints[1-i])
                checks += 1
            print(f"TerminalDB native agent integration checks: {checks} passed")
        finally:
            for client in clients: client.close()
            for process in reversed(processes):
                if process.poll() is None:
                    process.terminate()
                    try: process.wait(timeout=10)
                    except subprocess.TimeoutExpired: process.kill(); process.wait()
                subprocess.run(["defaults", "delete", "com.terminaldb.qa." + str(process.pid)], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


if __name__ == "__main__":
    main()
