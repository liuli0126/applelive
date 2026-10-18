"""Close the real packaged OBS with native USB running, isolated from user OBS."""
from pathlib import Path
import argparse
import ctypes as C
import ctypes.wintypes as W
import json
import os
import shutil
import socket
import subprocess
import sys
import threading
import time
import urllib.request
import psutil

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))
from importlib.util import spec_from_file_location, module_from_spec
spec = spec_from_file_location("startup_check", ROOT / "scripts/verify-portable-startup.py")
startup = module_from_spec(spec)
spec.loader.exec_module(startup)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path)
    parser.add_argument("output_dll", type=Path)
    args = parser.parse_args()
    test = ROOT / ".build/obs-shutdown-regression" / ("gui-" + str(time.time_ns()))
    target = test / "OBS"
    shutil.copytree(args.source, target)
    shutil.copy2(args.output_dll, target / "obs-plugins/64bit/applelive-native-output.dll")
    env = os.environ.copy()
    ports = {key: startup.free_port() for key in ["DOCK", "WEBSOCKET", "CONTROL", "RELAY"]}
    assert len(set(ports.values())) == 4
    env.update({f"APPLELIVE_TEST_{k}_PORT": str(v) for k, v in ports.items()})
    for name in ["APPDATA", "LOCALAPPDATA"]:
        path = test / name
        path.mkdir()
        env[name] = str(path)
    host = target / "bin/64bit/AppleLiveOBS.exe"
    user = C.WinDLL("user32")
    user.PostMessageW.argtypes = [W.HWND, W.UINT, W.WPARAM, W.LPARAM]
    callback = C.WINFUNCTYPE(W.BOOL, W.HWND, W.LPARAM)

    def process():
        for p in psutil.process_iter(["pid", "exe"]):
            if p.info["exe"] and Path(p.info["exe"]) == host:
                return p

    def ready():
        with urllib.request.urlopen(f"http://127.0.0.1:{ports['DOCK']}/api/status", timeout=3) as r:
            value = json.load(r)
        return value.get("ready") and value.get("usb", {}).get("native_available")

    def command(value):
        with socket.create_connection(("127.0.0.1", ports["CONTROL"]), 4) as s:
            s.sendall(value.encode())
            return s.recv(64).strip()

    def close(p):
        found = []
        @callback
        def visit(hwnd, _):
            pid = W.DWORD()
            user.GetWindowThreadProcessId(hwnd, C.byref(pid))
            if pid.value == p.pid and user.IsWindowVisible(hwnd):
                user.PostMessageW(hwnd, 0x10, 0, 0)
                found.append(hwnd)
            return True
        user.EnumWindows(visit, 0)
        assert found, "No test OBS window"
        return p.wait(timeout=25)

    results = []
    try:
        for case in ["active_usb_close", "reconnect_and_poll_during_close"]:
            launcher = subprocess.Popen([str(target / "福煋OBS.exe"), "--multi", "--disable-shutdown-check"], cwd=test, env=env)
            startup.wait_for(ready, 50)
            p = startup.wait_for(process)
            assert command("start") == b"ok"
            if case.startswith("reconnect"):
                for _ in range(8):
                    time.sleep(.15)
                    assert command("stop") == b"ok"
                    assert command("start") == b"ok"
            time.sleep(2)
            assert command("status") == b"running"
            errors = []
            done = threading.Event()
            def poll():
                while not done.is_set():
                    try:
                        reply = command("start")
                        if reply not in [b"ok", b"stopping", b""]:
                            errors.append(repr(reply))
                    except OSError:
                        return
                    done.wait(.03)
            thread = threading.Thread(target=poll)
            if case.startswith("reconnect"):
                thread.start()
            started = time.monotonic()
            code = close(p)
            done.set()
            if thread.is_alive():
                thread.join(5)
            assert code == 0, f"OBS crashed: {code}"
            assert launcher.wait(timeout=8) == 0
            assert not errors, errors
            startup.wait_for(lambda: not any(x.info["exe"] and str(target).lower() in x.info["exe"].lower() for x in psutil.process_iter(["exe"])), 15)
            logs = target / "config/obs-studio/logs"
            logfile = max(logs.glob("*.txt"), key=lambda f: f.stat().st_mtime)
            text = logfile.read_text(encoding="utf-8", errors="replace")
            marker = "native USB shutdown complete before OBS media teardown"
            assert text.count(marker) == 1, "Shutdown must run exactly once"
            assert text.index(marker) < text.index("All scene data cleared", text.index("==== Shutting down")), "Frontend shutdown hook did not run early"
            assert "Freeing OBS context data" in text
            results.append({"case": case, "exit": code, "close_seconds": round(time.monotonic() - started, 3), "log": str(logfile)})
            print("PASS", case, flush=True)
        (test / "result.json").write_text(json.dumps(results, indent=2), encoding="utf-8")
        print("Evidence:", test, flush=True)
    finally:
        for p in psutil.process_iter(["exe"]):
            if p.info["exe"] and str(target).lower() in p.info["exe"].lower():
                p.kill()

if __name__ == "__main__":
    main()
