# /// script
# requires-python = ">=3.11"
# ///
"""Every UI test, or some, over several simulators at once.

One build (`build-for-testing`), then a shard of the tests per simulator (`test-without-building`), each with its own
dev server, screenshot directory, and server requests (SendingUITests' stop, start and wipe), so a test that stops its
server stops nobody else's. The tests mostly wait on the agent (`$ sleep N`) and on animations, not on the CPU: three
simulators run them in about a third of the time.

Usage: uv run ios/scripts/uitests.py [-j N] [--keep] [Class/test | test ...]
  default: every test of TauUITests and SendingUITests, on 3 simulators
  -j N      simulators: "iPhone 17 Pro", then clones of it named "Tau UI <k>" (made the first time)
  --keep    leave the clones booted (they boot in about half a minute)

Shards are balanced by how long each test took last time (/tmp/tau-ui-durations.json). Screenshots end up in
/tmp/tau-ui as before, each shard's log in /tmp/tau-uitest-<k>.log.
"""

import json
import os
import re
import shutil
import subprocess
import sys
import threading
import time
from pathlib import Path

IOS = Path(__file__).resolve().parent.parent
DERIVED = os.environ.get("TAU_DERIVED_DATA", "/tmp/tau-dd")
SIMULATOR = os.environ.get("TAU_SIMULATOR", "iPhone 17 Pro")
DURATIONS = Path("/tmp/tau-ui-durations.json")
SCREENSHOTS = Path("/tmp/tau-ui")
CLASSES = ["TauUITests", "SendingUITests"]
# Shard 0 keeps the ports the single-simulator scripts use.
DEV_PORTS = [7979, 7991, 7992, 7993, 7994, 7995]
CACHE_PORT = 7982


def server_tokens() -> dict[str, str]:
    """This Mac's tau server's token and remote's, for the tests against them (TauUITests/SendingUITests.swift)."""
    local = Path.home() / ".config/tau/token"
    remote = subprocess.run(["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=5", "remote", "cat ~/.config/tau/token"], capture_output=True, text=True)
    return {
        "TEST_RUNNER_TAU_TOKEN": local.read_text().strip() if local.exists() else "",
        "TEST_RUNNER_TAU_REMOTE_TOKEN": remote.stdout.strip() if remote.returncode == 0 else "",
    }


def run(*args: str, **kwargs) -> subprocess.CompletedProcess:
    return subprocess.run(list(args), check=True, text=True, **kwargs)


def all_tests() -> list[str]:
    tests = []
    for name in CLASSES:
        source = (IOS / "TauUITests" / f"{name}.swift").read_text()
        tests += [f"{name}/{test}" for test in re.findall(r"^\s+func (test\w+)\(", source, re.M)]
    return tests


def qualify(names: list[str]) -> list[str]:
    tests = all_tests()
    out = []
    for name in names:
        if "/" in name:
            out.append(name)
            continue
        found = [test for test in tests if test.endswith(f"/{name}")]
        if not found:
            sys.exit(f"no test {name}")
        out += found
    return out


def devices() -> dict[str, dict]:
    listing = json.loads(run("xcrun", "simctl", "list", "devices", "available", "-j", capture_output=True).stdout)
    return {device["name"]: device for runtime in listing["devices"].values() for device in runtime}


def simulators(count: int) -> list[str]:
    """The simulators' UDIDs, cloning the first for the others the first time: a clone has its settings, permissions
    and keyboard as the tests expect them."""
    names = [SIMULATOR] + [f"Tau UI {k}" for k in range(1, count)]
    known = devices()
    if SIMULATOR not in known:
        sys.exit(f"no simulator {SIMULATOR}")
    missing = [name for name in names[1:] if name not in known]
    if missing:
        source = known[SIMULATOR]["udid"]
        subprocess.run(["xcrun", "simctl", "shutdown", source], capture_output=True)
        for name in missing:
            print(f"cloning {SIMULATOR} as {name}")
            run("xcrun", "simctl", "clone", source, name, capture_output=True)
        known = devices()
    udids = [known[name]["udid"] for name in names]
    for udid in udids:
        subprocess.run(["xcrun", "simctl", "boot", udid], capture_output=True)
    for udid in udids:
        run("xcrun", "simctl", "bootstatus", udid, "-b", capture_output=True)
    return udids


def balance(tests: list[str], count: int) -> list[list[str]]:
    """Longest first, each to the shard that ends soonest."""
    known = json.loads(DURATIONS.read_text()) if DURATIONS.exists() else {}
    default = sum(known.values()) / len(known) if known else 20.0
    shards: list[list[str]] = [[] for _ in range(count)]
    totals = [0.0] * count
    for test in sorted(tests, key=lambda test: -known.get(test, default)):
        index = totals.index(min(totals))
        shards[index].append(test)
        totals[index] += known.get(test, default)
    for index, total in enumerate(totals):
        print(f"shard {index}: {len(shards[index])} tests, about {total / 60:.1f} min")
    return shards


def dev_env(port: int) -> dict[str, str]:
    db = "/tmp/tau-dev.db" if port == DEV_PORTS[0] else f"/tmp/tau-dev-{port}.db"
    return {**os.environ, "TAU_DEV_PORT": str(port), "TAU_DEV_DB": db}


def devserver(action: str, port: int) -> None:
    subprocess.run([str(IOS / "scripts" / "devserver.sh"), action], env=dev_env(port), capture_output=True)


def serve_requests(directory: Path, port: int, stop: threading.Event) -> None:
    """SendingUITests asks for its server to stop, start or be wiped with a file, and waits for the answer."""
    while not stop.is_set():
        for action in ("stop", "start", "wipe"):
            request = directory / f"server-{action}"
            if request.exists():
                request.unlink()
                if action == "wipe":
                    devserver("stop", port)
                    devserver("wipe", port)
                    devserver("start", port)
                else:
                    devserver(action, port)
                (directory / f"server-{action}ed").touch()
        time.sleep(0.2)


def main() -> None:
    sys.stdout.reconfigure(line_buffering=True)
    args = sys.argv[1:]
    count, keep, names = 3, False, []
    while args:
        arg = args.pop(0)
        if arg == "-j":
            count = int(args.pop(0))
        elif arg == "--keep":
            keep = True
        else:
            names.append(arg)
    tests = qualify(names) if names else all_tests()
    count = max(1, min(count, len(tests), len(DEV_PORTS)))
    started = time.time()

    os.chdir(IOS)
    generate = ["xcodegen", "generate", "--quiet"]
    subprocess.run(generate if shutil.which("xcodegen") else ["nix", "shell", "nixpkgs#xcodegen", "-c", *generate], check=True)
    # A runner left from an earlier build can run old steps, or none: build it fresh each time.
    products = Path(DERIVED) / "Build/Products/Debug-iphonesimulator"
    shutil.rmtree(products / "TauUITests-Runner.app", ignore_errors=True)
    shutil.rmtree(products / "TauUITests.xctest", ignore_errors=True)
    common = ["-project", "Tau.xcodeproj", "-scheme", "Tau", "-derivedDataPath", DERIVED]
    signing = ["CODE_SIGN_IDENTITY=-", "CODE_SIGNING_REQUIRED=NO", "DEVELOPMENT_TEAM="]
    print("building")
    with open("/tmp/tau-uitest-build.log", "w") as log:
        built = subprocess.run(["xcodebuild", *common, "-destination", f"platform=iOS Simulator,name={SIMULATOR}", *signing, "build-for-testing"], stdout=log, stderr=subprocess.STDOUT)
    if built.returncode != 0:
        errors = [line for line in open("/tmp/tau-uitest-build.log") if "error:" in line]
        sys.exit("".join(sorted(set(errors))[:20]) or "build failed: /tmp/tau-uitest-build.log")
    print(f"built in {time.time() - started:.0f}s; booting {count} simulators")
    udids = simulators(count)

    # testPromptCache's server: the dev model with a 15 s prompt cache, priced so that warming it pays; in memory.
    cache = None
    if subprocess.run(["nc", "-z", "127.0.0.1", str(CACHE_PORT)], capture_output=True).returncode != 0:
        cache = subprocess.Popen(
            ["node", "--no-warnings", "src/main.ts", "--memory", "--port", str(CACHE_PORT), "--host", "127.0.0.1", "--dev-tps", "40", "--dev-cache-ttl", "15", "--cwd", "/tmp"],
            cwd=IOS.parent / "server", env={key: value for key, value in os.environ.items() if key != "OPENAI_API_KEY"},
            stdout=open("/tmp/tau-cache-server.log", "w"), stderr=subprocess.STDOUT,
        )

    shutil.rmtree(SCREENSHOTS, ignore_errors=True)
    stop = threading.Event()
    processes = []
    tokens = server_tokens()
    for index, shard in enumerate(balance(tests, count)):
        port = DEV_PORTS[index]
        # From an empty database: no test then finds what another left, such as a default model it changed.
        devserver("stop", port)
        devserver("wipe", port)
        devserver("start", port)
        directory = Path(f"/tmp/tau-ui-{index}")
        shutil.rmtree(directory, ignore_errors=True)
        directory.mkdir(parents=True)
        threading.Thread(target=serve_requests, args=(directory, port, stop), daemon=True).start()
        bundle = Path(f"/tmp/tau-uitest-{index}.xcresult")
        shutil.rmtree(bundle, ignore_errors=True)
        env = {**os.environ, **tokens, "TEST_RUNNER_TAU_DEV_SERVER": f"ws://127.0.0.1:{port}", "TEST_RUNNER_TAU_UI_DIR": str(directory)}
        command = ["xcodebuild", *common, "-destination", f"id={udids[index]}", "-resultBundlePath", str(bundle), *[f"-only-testing:TauUITests/{test}" for test in shard], "test-without-building"]
        processes.append((index, shard, subprocess.Popen(command, env=env, stdout=open(f"/tmp/tau-uitest-{index}.log", "w"), stderr=subprocess.STDOUT)))
        # Launches at once fight over the CPU; a few seconds apart they do not.
        time.sleep(5)

    durations = json.loads(DURATIONS.read_text()) if DURATIONS.exists() else {}
    passed, failed = [], []
    for index, shard, process in processes:
        process.wait()
        log = Path(f"/tmp/tau-uitest-{index}.log").read_text(errors="replace")
        for cls, test, result, seconds in re.findall(r"Test Case '-\[TauUITests\.(\w+) (\w+)\]' (passed|failed) \(([\d.]+) seconds\)", log):
            name = f"{cls}/{test}"
            # Averaged with the runs before: one run on a busy machine does not throw the balance off.
            durations[name] = round(0.5 * durations[name] + 0.5 * float(seconds), 1) if name in durations else float(seconds)
            (passed if result == "passed" else failed).append((name, float(seconds), index))
        ran = {name for name, _, _ in passed + failed}
        for name in shard:
            if name not in ran:
                failed.append((name, 0.0, index))
    stop.set()
    if cache is not None:
        cache.terminate()
    DURATIONS.write_text(json.dumps(durations, indent=1, sort_keys=True))

    SCREENSHOTS.mkdir(parents=True, exist_ok=True)
    for index in range(count):
        for shot in Path(f"/tmp/tau-ui-{index}").glob("*.png"):
            shutil.copy2(shot, SCREENSHOTS / shot.name)
    with open("/tmp/tau-uitest.log", "w") as merged:
        for index in range(count):
            merged.write(Path(f"/tmp/tau-uitest-{index}.log").read_text(errors="replace"))
    if not keep:
        for udid in udids[1:]:
            subprocess.run(["xcrun", "simctl", "shutdown", udid], capture_output=True)

    for name, seconds, index in failed:
        print(f"FAILED {name} ({seconds:.0f}s, shard {index})")
        log = Path(f"/tmp/tau-uitest-{index}.log").read_text(errors="replace")
        test = name.split("/")[1]
        for line in sorted({line.strip() for line in log.splitlines() if "error:" in line and test in line})[:5]:
            print(f"  {line[:300]}")
    print(f"{len(passed)} passed, {len(failed)} failed, in {(time.time() - started) / 60:.1f} min")
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
