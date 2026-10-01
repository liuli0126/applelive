"""Owned MediaMTX process for standard local RTMP/RTSP streams."""
from __future__ import annotations

import json
import socket
import subprocess
import sys
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
        self.process = None
        self.log = None

    @staticmethod
    def listening() -> bool:
        try:
            with socket.create_connection(("127.0.0.1", 1935), timeout=0.2):
                return True
        except OSError:
            return False

    def start(self) -> bool:
        if self.listening():
            return True
        executable = self.directory / "mediamtx.exe"
        if not executable.is_file():
            return False
        self.log = (self.directory / "applelive-server.log").open("ab")
        self.process = subprocess.Popen(
            [str(executable), str(self.directory / "mediamtx.yml")],
            stdin=subprocess.DEVNULL, stdout=self.log, stderr=subprocess.STDOUT,
            creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0),
        )
        for _ in range(40):
            if self.process.poll() is not None:
                self.stop()
                raise RuntimeError("Local streaming server failed; see server/applelive-server.log")
            if self.listening():
                return True
            time.sleep(0.1)
        self.stop()
        raise RuntimeError("Local streaming server did not open RTMP port 1935")

    def readers(self) -> int:
        try:
            with urlopen("http://127.0.0.1:9997/v3/paths/list", timeout=0.15) as response:
                paths = json.load(response)["items"]
            return sum(len(path.get("readers", [])) for path in paths if path.get("name") == "live/applelive")
        except (OSError, ValueError, KeyError, TypeError):
            return 0

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
