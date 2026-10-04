"""Loopback-only AppleLive browser dock backed by OBS WebSocket 5."""
from __future__ import annotations

import argparse
import ipaddress
import json
import os
from pathlib import Path
import secrets
import socket
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlsplit

from obs_websocket import OBSClient, OBSConnectionError
from phone_plugin import plugin_path
from stream_server import StreamServer

DESKTOP_VERSION = "0.2.5"


def machine_id() -> str:
    if os.name != "nt":
        return socket.gethostname()
    try:
        import winreg
        with winreg.OpenKey(winreg.HKEY_LOCAL_MACHINE, r"SOFTWARE\Microsoft\Cryptography") as key:
            return str(winreg.QueryValueEx(key, "MachineGuid")[0]).strip()
    except OSError:
        return socket.gethostname()


def local_addresses() -> list[str]:
    candidates: set[str] = set()
    route_address = ""
    try:
        candidates.update(a[4][0] for a in socket.getaddrinfo(socket.gethostname(), None, socket.AF_INET))
    except OSError:
        pass
    probe = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        probe.connect(("192.0.2.1", 9))
        route_address = probe.getsockname()[0]
        candidates.add(route_address)
    except OSError:
        pass
    finally:
        probe.close()
    valid = []
    for value in candidates:
        try:
            address = ipaddress.IPv4Address(value)
        except ipaddress.AddressValueError:
            continue
        if address.is_loopback or address.is_multicast or address.is_unspecified or value.startswith("169.254."):
            continue
        valid.append(str(address))
    ordered = sorted(set(valid), key=lambda value: (not ipaddress.IPv4Address(value).is_private, value))
    if route_address in ordered:
        ordered.remove(route_address)
        ordered.insert(0, route_address)
    return ordered


def validate_command(value: dict) -> dict:
    if not isinstance(value, dict) or value.get("action") not in {"configure_stream", "start_stream", "stop_stream"}:
        raise ValueError("无效的操作")
    if set(value) - {"action", "host"}:
        raise ValueError("不支持的设置")
    host = value.get("host", "")
    if value["action"] == "configure_stream":
        try:
            host = str(ipaddress.IPv4Address(host))
        except (ipaddress.AddressValueError, TypeError):
            raise ValueError("电脑局域网 IP 无效") from None
    elif host:
        raise ValueError("此操作不需要 IP")
    return {"action": value["action"], "host": host}


class DockServer(ThreadingHTTPServer):
    daemon_threads = True

    def __init__(self, directory: Path, port: int):
        self.directory = directory
        self.token = secrets.token_urlsafe(32)
        self.command_lock = threading.Lock()
        self.last_command = ""
        self.addresses = local_addresses()
        super().__init__(("127.0.0.1", port), Handler)
        self.origin = f"http://127.0.0.1:{self.server_port}"
        self.stream_server = StreamServer(directory / "server")
        self.stream_error = ""
        self.firewall_pending = False
        self.firewall_error = ""

    def server_close(self):
        self.stream_server.stop()
        super().server_close()

    def ensure_stream_server(self):
        try:
            if not self.stream_server.start():
                raise OSError("缺少 server/mediamtx.exe，请安装完整 OBS 插件包")
            self.stream_error = ""
        except (OSError, RuntimeError) as error:
            self.stream_error = str(error)
            raise

    def stop_stream_server(self):
        self.stream_server.stop()
        self.stream_error = ""

    def firewall_access_enabled(self) -> bool:
        try:
            marker = (self.directory / "lan-access.ok").read_text(encoding="ascii").strip()
        except OSError:
            return False
        return marker == f"AppleLiveLAN2:{machine_id()}"

    def _run_firewall_setup(self, script: Path) -> None:
        import ctypes
        arguments = f'-NoProfile -ExecutionPolicy Bypass -File "{script}"'
        shell_execute = ctypes.windll.shell32.ShellExecuteW
        shell_execute.restype = ctypes.c_void_p
        result = shell_execute(None, "runas", "powershell.exe", arguments, str(self.directory), 0)
        if not result or result <= 32:
            raise OSError(f"无法打开 Windows 授权窗口（错误 {result}）")

    def status(self) -> dict:
        bridge = {"stream_active": False, "stream_configured": False,
                  "stream_server": "", "last_command": self.last_command, "command_error": ""}
        ready, obs_error = False, ""
        try:
            with OBSClient(self.directory) as client:
                bridge.update(client.stream_state())
                ready = True
        except OBSConnectionError as error:
            obs_error = str(error)
        path = self.stream_server.path_status()
        return {"ready": ready, "bridge": bridge, "obs_error": obs_error,
                "addresses": self.addresses, "token": self.token, "pending": False,
                "desktop_version": DESKTOP_VERSION,
                "stream_server_ready": self.stream_server.ready(), "stream_error": self.stream_error,
                "firewall_ready": self.firewall_access_enabled(),
                "firewall_pending": self.firewall_pending, "firewall_error": self.firewall_error,
                "stream_path": path,
                "phone_plugin": {"available": plugin_path(self.directory).is_file()}}

    def request_firewall_access(self) -> None:
        if os.name != "nt":
            raise OSError("Windows firewall setup is only available on Windows")
        script = self.directory / "setup_lan.ps1"
        if not script.is_file():
            raise OSError("Missing setup_lan.ps1")
        if self.firewall_pending:
            return
        (self.directory / "lan-access.ok").unlink(missing_ok=True)
        self.firewall_pending = True
        self.firewall_error = ""

        def elevate():
            try:
                self._run_firewall_setup(script)
                for _ in range(100):
                    if self.firewall_access_enabled():
                        return
                    time.sleep(0.1)
                self.firewall_error = "授权没有完成，请再次点击授权按钮"
            except (OSError, TypeError, ValueError) as error:
                self.firewall_error = str(error)
            finally:
                self.firewall_pending = False

        threading.Thread(target=elevate, daemon=True).start()


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_args):
        pass

    def reply(self, status: int, body: bytes, content_type="application/json; charset=utf-8", filename=None):
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        if filename:
            self.send_header("Content-Disposition", f'attachment; filename="{filename}"')
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("Content-Security-Policy", "default-src 'self'; script-src 'self'; style-src 'self'; frame-ancestors 'none'")
        self.end_headers()
        self.wfile.write(body)

    def json_reply(self, status: int, value: dict):
        self.reply(status, json.dumps(value, ensure_ascii=False).encode("utf-8"))

    def valid_host(self):
        return self.headers.get("Host") == f"127.0.0.1:{self.server.server_port}"

    def do_GET(self):
        if not self.valid_host():
            self.json_reply(403, {"error": "Host rejected"})
            return
        if self.path == "/api/status":
            self.json_reply(200, self.server.status())
            return
        url = urlsplit(self.path)
        if url.path == "/api/phone-plugin" and not url.query:
            try:
                body = plugin_path(self.server.directory).read_bytes()
            except OSError:
                self.json_reply(404, {"error": "手机插件文件缺失，请安装完整 OBS 插件包"})
                return
            self.reply(200, body, "application/octet-stream", "AppleLive.dylib")
            return
        files = {"/": ("index.html", "text/html; charset=utf-8"),
                 "/app.js": ("app.js", "text/javascript; charset=utf-8"),
                 "/style.css": ("style.css", "text/css; charset=utf-8")}
        if self.path not in files:
            self.json_reply(404, {"error": "Not found"})
            return
        name, kind = files[self.path]
        try:
            self.reply(200, (self.server.directory / "dock" / name).read_bytes(), kind)
        except OSError:
            self.json_reply(500, {"error": "停靠面板文件缺失，请完整解压插件包"})

    def do_POST(self):
        if (not self.valid_host() or self.path not in {"/api/command", "/api/firewall"}
                or self.headers.get("Origin") != self.server.origin
                or not secrets.compare_digest(self.headers.get("X-AppleLive-Token", ""), self.server.token)):
            self.json_reply(403, {"error": "Request rejected"})
            return
        if self.path == "/api/firewall":
            try:
                self.server.request_firewall_access()
            except (OSError, TypeError, ValueError) as error:
                self.json_reply(500, {"error": str(error)})
                return
            self.json_reply(202, {"status": "requested"})
            return
        try:
            length = int(self.headers.get("Content-Length", "0"))
            if not 0 < length <= 4096:
                raise ValueError("请求长度无效")
            command = validate_command(json.loads(self.rfile.read(length)))
        except (ValueError, TypeError) as error:
            self.json_reply(400, {"error": str(error)})
            return
        with self.server.command_lock:
            if command["action"] == "configure_stream" and command["host"] not in self.server.addresses:
                self.json_reply(400, {"error": "请选择这台电脑的局域网 IP"})
                return
            try:
                if command["action"] in {"configure_stream", "start_stream"}:
                    self.server.ensure_stream_server()
                with OBSClient(self.server.directory) as client:
                    if command["action"] == "configure_stream":
                        client.configure(command["host"])
                    elif command["action"] == "start_stream":
                        client.start()
                    else:
                        client.stop()
                        self.server.stop_stream_server()
            except (OBSConnectionError, OSError, RuntimeError) as error:
                self.json_reply(503, {"error": str(error)})
                return
            self.server.last_command = secrets.token_hex(8)
        self.json_reply(202, {"id": self.server.last_command})


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--directory", type=Path, required=True)
    parser.add_argument("--port", type=int, default=18765)
    parser.add_argument("--obs-pid", type=int, default=0)
    args = parser.parse_args()
    try:
        server = DockServer(args.directory.resolve(), args.port)
    except OSError:
        return
    started = time.time()

    def watch_obs():
        handle = None
        if os.name == "nt" and args.obs_pid:
            import ctypes
            from ctypes import wintypes
            kernel = ctypes.WinDLL("kernel32", use_last_error=True)
            kernel.OpenProcess.argtypes = [wintypes.DWORD, wintypes.BOOL, wintypes.DWORD]
            kernel.OpenProcess.restype = wintypes.HANDLE
            kernel.WaitForSingleObject.argtypes = [wintypes.HANDLE, wintypes.DWORD]
            kernel.CloseHandle.argtypes = [wintypes.HANDLE]
            handle = kernel.OpenProcess(0x00100000, False, args.obs_pid)
        if handle:
            try:
                while kernel.WaitForSingleObject(handle, 2000) == 258:
                    pass
            finally:
                kernel.CloseHandle(handle)
        else:
            last_seen = started
            while time.time() - last_seen < 120:
                if server.status()["ready"]:
                    last_seen = time.time()
                time.sleep(2)
        server.shutdown()

    threading.Thread(target=watch_obs, daemon=True).start()
    try:
        server.serve_forever(poll_interval=0.5)
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
