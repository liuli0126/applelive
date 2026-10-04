"""Owned MediaMTX process for standard local RTMP/RTSP streams."""
from __future__ import annotations

import json
import os
import socket
import subprocess
import sys
import tempfile
import time
from pathlib import Path
from urllib.request import urlopen

RTMP_URL = "rtmp://127.0.0.1:1935/live/applelive"


def server_directory() -> Path:
    root = Path(sys.executable).parent if getattr(sys, "frozen", False) else Path(__file__).resolve().parents[1] / "obs-plugin"
    return root / "server"


class StreamServer:
    def __init__(self, directory: Path | None = None):
        self.directory = directory or server_directory()
        runtime_root = Path(os.environ.get("LOCALAPPDATA", tempfile.gettempdir()))
        self.runtime_directory = runtime_root / "AppleLive"
        self.process = None
        self.log = None

    @staticmethod
    def listening() -> bool:
        try:
            with socket.create_connection(("127.0.0.1", 1935), timeout=0.2):
                return True
        except OSError:
            return False

    @staticmethod
    def ready() -> bool:
        try:
            with socket.create_connection(("127.0.0.1", 8554), timeout=0.2):
                with urlopen("http://127.0.0.1:9997/v3/paths/list", timeout=0.2) as response:
                    return isinstance(json.load(response).get("items"), list)
        except (OSError, ValueError, TypeError):
            return False

    def start(self) -> bool:
        if self.listening():
            if not self.ready():
                raise RuntimeError("端口 1935 已被其他服务占用，且 RTSP/MediaMTX 未就绪")
            return True
        executable = self.directory / "mediamtx.exe"
        if not executable.is_file():
            return False
        self.runtime_directory.mkdir(parents=True, exist_ok=True)
        self.log = (self.runtime_directory / "applelive-server.log").open("ab")
        self.process = subprocess.Popen(
            [str(executable), str(self.directory / "mediamtx.yml")],
            stdin=subprocess.DEVNULL, stdout=self.log, stderr=subprocess.STDOUT,
            creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0),
        )
        for _ in range(40):
            if self.process.poll() is not None:
                self.stop()
                raise RuntimeError("Local streaming server failed; see server/applelive-server.log")
            if self.listening() and self.ready():
                return True
            time.sleep(0.1)
        self.stop()
        raise RuntimeError("Local streaming server did not open RTMP port 1935")

    def readers(self) -> int:
        return self.path_status()["readers"]

    def path_status(self) -> dict:
        empty = {"ready": False, "readers": 0, "tracks": []}
        try:
            with urlopen("http://127.0.0.1:9997/v3/paths/list", timeout=0.15) as response:
                paths = json.load(response)["items"]
            path = next((path for path in paths if path.get("name") == "live/applelive"), None)
            if path is None:
                return empty
            return {"ready": bool(path.get("ready")), "readers": len(path.get("readers", [])),
                    "tracks": path.get("tracks", [])}
        except (OSError, ValueError, KeyError, TypeError):
            return empty

    def stop(self) -> None:
        if self.process:
            if self.process.poll() is None:
                self.process.terminate()
                try:
                    self.process.wait(timeout=3)
                except subprocess.TimeoutExpired:
                    self.process.kill(); self.process.wait(timeout=3)
            self.process = None
        if self.log:
            self.log.close(); self.log = None
