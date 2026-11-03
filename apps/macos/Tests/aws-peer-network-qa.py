#!/usr/bin/env python3
"""Actual native-agent AWS sharing checks using only disposable synthetic data.

Requires Bonjour/Local Network permission. This supplements visible physical
QA; it never reads normal AWS configuration/caches or uses a real AWS process.
Credential-process stdout is captured privately and never included in failures.
"""
import configparser
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import signal
import socket
import subprocess
import sys
import tempfile

spec = importlib.util.spec_from_file_location("session_qa", Path(__file__).with_name("peer-session-qa.py"))
qa = importlib.util.module_from_spec(spec)
spec.loader.exec_module(qa)
Client, wait_for = qa.Client, qa.wait_for


FAKE_AWS = r'''#!/usr/bin/env python3
import configparser, datetime, fcntl, hashlib, json, os, shlex, subprocess, sys, uuid
from pathlib import Path

root = Path(__file__).resolve().parent.parent
assert os.environ.get("TERMINALDB_PEER_QA") == "1"
assert os.environ.get("TERMINALDB_PEER_EPHEMERAL_IDENTITY") == "1"
config_path = Path(os.environ["AWS_CONFIG_FILE"]).resolve()
assert config_path.is_relative_to(root)
parser = configparser.RawConfigParser()
parser.read(config_path)
args = sys.argv[1:]
profile = args[args.index("--profile") + 1] if "--profile" in args else "default"
section = "default" if profile == "default" else "profile " + profile

def profile_values():
    assert parser.has_section(section)
    return dict(parser[section])

def process_credentials():
    values = profile_values()
    if "credential_process" in values:
        command = shlex.split(values["credential_process"])
        assert len(command) == 3 and command[1] == "--aws-credentials"
        assert len(command[2]) == 64
        result = subprocess.run(command, env=os.environ, capture_output=True, timeout=55)
        assert result.returncode == 0 and len(result.stdout) < 32768
        return json.loads(result.stdout)
    if values.get("sso_session"):
        cache = root / ".aws/sso/cache" / (hashlib.sha1(values["sso_session"].encode()).hexdigest() + ".json")
        token = json.loads(cache.read_text())
        assert token["accessToken"].startswith("tdb-test-")
        assert datetime.datetime.fromisoformat(token["expiresAt"].replace("Z", "+00:00")) > datetime.datetime.now(datetime.timezone.utc)
    else:
        marker = root / "aws-fixture" / ("signed-in-" + hashlib.sha256(profile.encode()).hexdigest())
        assert marker.exists()
    account, role = values["sso_account_id"], values["sso_role_name"]
    cache = root / "aws-fixture" / ("role-" + hashlib.sha256((account + role).encode()).hexdigest() + ".json")
    # Concurrent alias exports share one role cache and one fixed expiration.
    # Readers participate in the same lock, so no partial JSON is observable.
    with (root / "aws-fixture/roles.lock").open("a") as lock:
        os.chmod(lock.name, 0o600)
        fcntl.flock(lock.fileno(), fcntl.LOCK_EX)
        if not cache.exists():
            now = datetime.datetime.now(datetime.timezone.utc)
            expiration = now + datetime.timedelta(minutes=30)
            value = {"Version": 1,
                     "AccessKeyId": "tdb-test-" + role + "-" + account,
                     "SecretAccessKey": "tdb-test-secret-" + hashlib.sha256((account + role).encode()).hexdigest(),
                     "SessionToken": "tdb-test-session-" + hashlib.sha256((role + account).encode()).hexdigest(),
                     "Expiration": expiration.isoformat(timespec="milliseconds").replace("+00:00", "Z")}
            cache.write_text(json.dumps(value)); cache.chmod(0o600)
        return json.loads(cache.read_text())

if args[:2] == ["sso", "login"] or args[:1] == ["login"]:
    if "--sso-session" in args:
        session = args[args.index("--sso-session") + 1]
        settings = parser["sso-session " + session]
        cache = root / ".aws/sso/cache"
        cache.mkdir(parents=True, mode=0o700, exist_ok=True)
        token = cache / (hashlib.sha1(session.encode()).hexdigest() + ".json")
        temporary = token.with_name(token.name + ".tmp-" + uuid.uuid4().hex)
        temporary.write_text(json.dumps({"accessToken":"tdb-test-generic-audit-sso", "startUrl":settings["sso_start_url"], "region":settings["sso_region"], "expiresAt":(datetime.datetime.now(datetime.timezone.utc)+datetime.timedelta(hours=1)).strftime("%Y-%m-%dT%H:%M:%SZ")})); temporary.chmod(0o600)
        os.replace(temporary, token)
    else:
        profile_values()
        marker = root / "aws-fixture" / ("signed-in-" + hashlib.sha256(profile.encode()).hexdigest())
        marker.write_text("ready"); marker.chmod(0o600)
elif args[:2] == ["configure", "export-credentials"]:
    print(json.dumps(process_credentials()))
elif args[:2] == ["sts", "get-caller-identity"]:
    if "AWS_ACCESS_KEY_ID" in os.environ:
        access = os.environ["AWS_ACCESS_KEY_ID"]
        assert os.environ["AWS_SECRET_ACCESS_KEY"].startswith("tdb-test-")
        assert os.environ["AWS_SESSION_TOKEN"].startswith("tdb-test-")
    else:
        value = process_credentials()
        assert value["Version"] == 1
        assert all(value[key].startswith("tdb-test-") for key in ["AccessKeyId", "SecretAccessKey", "SessionToken"])
        access = value["AccessKeyId"]
    assert access.startswith("tdb-test-")
    role, account = access[len("tdb-test-"):].rsplit("-", 1)
    assert len(account) == 12 and account.isdigit() and role in ["Developer", "Auditor"]
    arn = "arn:aws:sts::" + account + ":assumed-role/AWSReservedSSO_" + role + "_0123456789abcdef/synthetic"
    print(json.dumps({"Account": account, "Arn": arn, "UserId": "synthetic"}))
elif args == ["--version"]:
    print("aws-cli/2.99.0 fixture")
else:
    raise SystemExit(64)
'''


def source_profile(name, role):
    return (f"[profile {name}]\nsso_session = fixture-session\nsso_account_id = 123456789012\n"
            f"sso_role_name = {role}\nregion = us-east-1\n")


def environment(root):
    env = {key: value for key, value in os.environ.items() if not key.startswith("AWS_")}
    env.pop("PYTHONHOME", None)
    env.pop("PYTHONPATH", None)
    env.update(TERMINALDB_PEER_STATE_DIR=str(root), TERMINALDB_PEER_EPHEMERAL_IDENTITY="1",
               TERMINALDB_PEER_QA="1", TERMINALDB_AWS_QA_EXECUTABLE=str(root / "bin/aws"),
               AWS_CONFIG_FILE=str(root / "aws-fixture/config"), HOME=str(root),
               PATH=str(root / "bin") + ":/usr/bin:/bin:/usr/sbin:/sbin")
    return env


def run_private(command, env):
    """Never expose process output or interpolate a secret-bearing exception."""
    return subprocess.run(command, env=env, capture_output=True, timeout=60)


def main():
    app = Path(sys.argv[1]).resolve()
    if app.suffix == ".app":
        app = app / "Contents/MacOS/TerminalDB"
    assert app.is_file()
    processes, clients, paused = [], [], set()
    checks = 0
    with tempfile.TemporaryDirectory(prefix="tdb-aws-net-", dir="/tmp") as directory:
        roots = [Path(directory) / name for name in ["a", "b"]]
        hosts, agents = [], []
        try:
            for index, root in enumerate(roots):
                root.mkdir(mode=0o700)
                (root / "bin").mkdir(mode=0o700)
                fixture = root / "aws-fixture"; fixture.mkdir(mode=0o700)
                content = "# Disposable configuration. Normal AWS files are untouched.\n[default]\nregion = us-west-2\n"
                if index == 0:
                    content += source_profile("fixture-work", "Developer")
                    content += "[sso-session fixture-session]\nsso_start_url = https://fixture.awsapps.com/start\nsso_region = us-east-1\n"
                (fixture / "config").write_text(content); (fixture / "config").chmod(0o600)
                fake = root / "bin/aws"; fake.write_text(FAKE_AWS); fake.chmod(0o700)
                reservation = socket.socket(); reservation.bind(("127.0.0.1", 0))
                port = reservation.getsockname()[1]; reservation.close()
                trust = root / "trust.json"
                trust.write_text(json.dumps(dict(peers={}, listenPort=port))); trust.chmod(0o600)
                for role, target in [("TerminalDBSessionHost", hosts), ("TerminalDBPeerAgent", agents)]:
                    executable = qa.helper_executable(app, role)
                    process = subprocess.Popen([str(executable), "--terminal-qa"], env=environment(root),
                                               stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                    processes.append(process); target.append(process)
                wait_for(lambda: (root / "peer.sock").exists() and (root / "host.sock").exists())

            managers = [Client(root, management=True) for root in roots]
            locals_ = [Client(root) for root in roots]
            clients += managers + locals_

            def state(i): return managers[i].request("peers.state")
            def catalog(i):
                result = locals_[i].request("aws.catalog")
                assert "error" not in result
                return result
            def accounts(i): return catalog(i)["accounts"]
            def available(i, profile_id):
                return any(item["profileId"] == profile_id and item["available"] for item in accounts(i))
            def sync():
                for manager in managers: assert "error" not in manager.request("aws.sync.now")

            fingerprints = [state(i)["fingerprint"] for i in range(2)]
            wait_for(lambda: all(any(item["service"] == "tdb-" + fingerprints[1-i][:12]
                                     for item in state(i)["nearby"]) for i in range(2)), timeout=20)
            for manager in managers: assert "error" not in manager.request("peers.pairing.open")
            wait_for(lambda: all(any(item["service"] == "tdb-" + fingerprints[1-i][:12] and item["pairingReady"]
                                     for item in state(i)["nearby"]) for i in range(2)), timeout=20)
            assert "error" not in managers[0].request("peers.pair", service="tdb-" + fingerprints[1][:12])
            wait_for(lambda: all(any(item["fingerprint"] == fingerprints[1-i] and item.get("ready")
                                    for item in state(i)["candidates"]) for i in range(2)))
            for i, manager in enumerate(managers):
                candidate = next(item for item in state(i)["candidates"] if item["fingerprint"] == fingerprints[1-i])
                assert "error" not in manager.request("peers.approve", candidate=candidate["id"], fingerprint=fingerprints[1-i])
            wait_for(lambda: all(state(i)["peers"] for i in range(2)))
            for manager in managers: manager.request("peers.pairing.close")
            checks += 1

            assert all(not state(i).get("awsPeers") for i in range(2))
            for i, manager in enumerate(managers):
                assert "error" not in manager.request("accounts.sync.configure", peers=[fingerprints[1-i]])
            assert all(not state(i).get("awsPeers") for i in range(2))
            checks += 1

            source = next(item for item in catalog(0)["profiles"] if item["name"] == "fixture-work")
            profile_id = source["id"]
            native_source_config = (roots[0] / "aws-fixture/config").read_bytes()
            assert not accounts(0) and not accounts(1)
            assert locals_[0].request("aws.signIn.start", profileId=profile_id).get("accepted")
            wait_for(lambda: available(0, profile_id), timeout=15)
            assert (roots[0] / "aws-fixture/config").read_bytes() == native_source_config
            assert not accounts(1)
            checks += 1

            assert "error" not in locals_[0].request("aws.source.enable", profileId=profile_id)
            parser = configparser.RawConfigParser(); parser.read(roots[0] / "aws-fixture/config")
            assert "credential_process" not in parser["profile fixture-work"] and "sso_session" in parser["profile fixture-work"]
            assert (roots[0] / "aws-fixture/config").read_bytes() == native_source_config
            assert not catalog(0)["installed"]
            checks += 1

            assert "error" not in managers[0].request("aws.sync.configure", peers=[fingerprints[1]])
            sync()
            wait_for(lambda: "Enable AWS sync" in state(0).get("awsStatus", {}).get(fingerprints[1], ""), timeout=40)
            assert not accounts(1)
            checks += 1

            assert "error" not in managers[1].request("aws.sync.configure", peers=[fingerprints[0]])
            sync(); wait_for(lambda: available(1, profile_id), timeout=40)
            assert accounts(1)[0]["profileId"] == profile_id
            checks += 1

            assert "error" not in locals_[1].request("aws.use", profileId=profile_id, targetName="fixture-work")
            host_executable = qa.helper_executable(app, "TerminalDBSessionHost")
            def launch(i, identity=profile_id):
                result = run_private([str(host_executable), "--aws-credentials", identity], environment(roots[i]))
                if result.returncode != 0: return None
                value = json.loads(result.stdout)
                assert value.get("Version") == 1
                assert all(value.get(key, "").startswith("tdb-test-") for key in ["AccessKeyId", "SecretAccessKey", "SessionToken"])
                return value
            credential = launch(1)
            assert credential is not None
            checks += 1

            ordinary = run_private([str(roots[1] / "bin/aws"), "sts", "get-caller-identity", "--profile", "fixture-work"], environment(roots[1]))
            assert ordinary.returncode == 0
            assert json.loads(ordinary.stdout).get("Account") == "123456789012"
            checks += 1

            remote = Client(roots[0], peer_id=fingerprints[1]); clients.append(remote)
            created = remote.request("session.create", directory=str(roots[1]), private=True)
            assert "error" not in created
            remote.session, remote.generation = created["sessionId"], created["generation"]
            assert remote.request("aws.catalog").get("accounts")
            assert "error" in remote.request("aws.credentials", profileId=profile_id)
            assert "error" in remote.request("aws.sync.export")
            assert "error" in remote.request("aws.sync.import", bundle={})
            checks += 1

            for root in roots:
                assert b"tdb-test-" not in (root / "shared-aws.json").read_bytes()
            checks += 1

            # Equal metadata must still repair a missing local secret copy.
            for manager in managers:
                assert "error" not in manager.request("aws.sync.configure", peers=[])
            old_bundle = locals_[0].request("aws.sync.export")["bundle"]
            versions = [role for source in old_bundle["sources"].values() for role in source["roles"].values()
                        if role["profile"]["id"] == profile_id]
            assert versions
            secret = roots[1] / "fixture-aws-credentials" / versions[0]["credential"]
            assert secret.parent == roots[1] / "fixture-aws-credentials" and secret.exists()
            secret.unlink()
            wait_for(lambda: not available(1, profile_id))
            assert launch(1) is None
            for i, manager in enumerate(managers):
                assert "error" not in manager.request("aws.sync.configure", peers=[fingerprints[1-i]])
            sync(); wait_for(lambda: available(1, profile_id), timeout=40)
            assert launch(1) == credential
            checks += 1

            # Turning AWS off affects only AWS transfers, not terminal control.
            generation = remote.generation
            assert "error" not in managers[0].request("aws.sync.configure", peers=[])
            assert remote.request("health.ping").get("accepted") and remote.generation == generation
            assert remote.input("printf ready > aws-scope-terminal-check\r").get("accepted")
            wait_for(lambda: (roots[1] / "aws-scope-terminal-check").exists())
            assert "error" not in managers[0].request("aws.sync.configure", peers=[fingerprints[1]])
            checks += 1

            # Suspend just the source networking process: receiving Macs keep
            # their cached credentials and the source may add a login while away.
            agents[0].send_signal(signal.SIGSTOP); paused.add(agents[0])
            assert launch(1) == credential
            assert locals_[1].request("health.ping").get("accepted")
            checks += 1
            source_config = roots[0] / "aws-fixture/config"
            source_config.write_text(source_config.read_text() + "\n" + source_profile("fixture-offline", "Auditor"))
            offline = next(item for item in catalog(0)["profiles"] if item["name"] == "fixture-offline")
            offline_id = offline["id"]
            assert locals_[0].request("aws.signIn.start", profileId=offline_id).get("accepted")
            wait_for(lambda: available(0, offline_id), timeout=15)
            assert not available(1, offline_id)
            checks += 1
            agents[0].send_signal(signal.SIGCONT); paused.remove(agents[0])
            sync(); wait_for(lambda: available(1, offline_id), timeout=40)
            assert launch(1, offline_id) is not None
            checks += 1

            # Withdrawal wins over a delayed older source snapshot.
            assert "error" not in locals_[0].request("aws.remove", profileId=profile_id)
            assert not available(0, profile_id)
            sync(); wait_for(lambda: not any(item["profileId"] == profile_id for item in accounts(1)), timeout=40)
            assert "error" not in locals_[1].request("aws.sync.import", bundle=old_bundle)
            assert not any(item["profileId"] == profile_id for item in accounts(1))
            assert launch(1) is None and available(1, offline_id)
            checks += 1

            # A receiving installation can be explicitly restored without
            # erasing another shared role or touching an ordinary source login.
            assert "error" not in locals_[1].request("aws.remove", profileId=profile_id)
            parser = configparser.RawConfigParser(); parser.read(roots[1] / "aws-fixture/config")
            assert not parser.has_section("profile fixture-work")
            assert available(1, offline_id)
            checks += 1

            assert "error" not in managers[1].request("peers.remove", peerId=fingerprints[0])
            assert not state(1).get("awsPeers")
            try:
                remote.request("session.list")
            except (OSError, RuntimeError):
                pass
            else:
                raise AssertionError("Revoked terminal access remained available")
            assert locals_[1].request("health.ping").get("accepted")
            assert available(1, offline_id)  # Already copied temporary keys expire normally.
            checks += 1

            # The sender owns its SSO login. Its token cache never reaches a
            # receiving Mac that only uses shared temporary role credentials.
            assert (roots[0] / ".aws/sso/cache").exists()
            assert not (roots[1] / ".aws/sso/cache").exists()
            assert all(host.poll() is None for host in hosts)
            checks += 1
            # A receiving Mac can already have a native profile with an
            # expired local SSO login. Valid shared access remains independent
            # of that login, including while the source is unreachable.
            receiving_config = roots[1] / "aws-fixture/config"
            receiving_config.write_text(receiving_config.read_text() + "\n[profile receiver-existing]\nsso_session = receiver-session\nsso_account_id = 123456789012\nsso_role_name = Auditor\nregion = us-east-1\n\n[sso-session receiver-session]\nsso_start_url = https://fixture.awsapps.com/start\nsso_region = us-east-1\n")
            receiving_config.chmod(0o600)
            for directory in [roots[1] / ".aws", roots[1] / ".aws/sso", roots[1] / ".aws/sso/cache"]:
                directory.mkdir(mode=0o700, exist_ok=True)
            local_cache = roots[1] / ".aws/sso/cache" / (hashlib.sha1(b"receiver-session").hexdigest() + ".json")
            local_cache.write_text(json.dumps({"accessToken": "tdb-test-expired-local-sso", "startUrl": "https://fixture.awsapps.com/start", "region": "us-east-1", "expiresAt": "2020-01-01T00:00:00Z"}))
            local_cache.chmod(0o600)
            original_receiver = receiving_config.read_bytes()
            original_local_cache = local_cache.read_bytes()
            assert "error" in locals_[1].request("aws.use", profileId=offline_id, targetName="receiver-existing")
            assert receiving_config.read_bytes() == original_receiver
            checks += 1

            assert "error" not in locals_[1].request("aws.use", profileId=offline_id, targetName="receiver-existing", replaceSource=True)
            receiving_state = catalog(1)
            assert receiving_state["authentication"][offline_id]["state"] == "expired"
            shared = next(item for item in receiving_state["accounts"] if item["profileId"] == offline_id)
            assert shared["available"] and not shared["local"]
            received_command = run_private([str(roots[1] / "bin/aws"), "sts", "get-caller-identity", "--profile", "receiver-existing"], environment(roots[1]))
            assert received_command.returncode == 0
            assert json.loads(received_command.stdout).get("Account") == "123456789012"
            assert local_cache.read_bytes() == original_local_cache
            assert sorted(path.name for path in local_cache.parent.iterdir()) == [local_cache.name]
            checks += 1

            assert "error" not in locals_[1].request("aws.remove", profileId=offline_id)
            assert receiving_config.read_bytes() == original_receiver
            assert local_cache.read_bytes() == original_local_cache
            assert launch(1, offline_id) is not None
            checks += 1

            print(f"TerminalDB AWS native agent integration checks: {checks} passed")
        except (Exception, KeyboardInterrupt):
            # No repr/traceback: a failed subprocess/JSON assertion can retain
            # secret-bearing protocol data in exception context.
            raise SystemExit(f"TerminalDB AWS native agent integration failed after {checks} checks") from None
        finally:
            for process in paused:
                if process.poll() is None: process.send_signal(signal.SIGCONT)
            for client in clients:
                try: client.close()
                except OSError: pass
            for process in reversed(processes):
                if process.poll() is None:
                    process.terminate()
                    try: process.wait(timeout=10)
                    except subprocess.TimeoutExpired:
                        process.kill(); process.wait(timeout=5)


if __name__ == "__main__":
    main()
