"""Loopback-only OBS browser dock. OBS Lua owns capture and applies commands."""
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
from io import BytesIO
from urllib.parse import parse_qs, urlsplit
from phone_plugin import download_name, download_url, plugin_path


def read_json(path: Path) -> dict:
    try:
        return json.loads(path.read_text(encoding="utf-8-sig"))
    except (OSError, ValueError):
        return {}


def atomic_json(path: Path, value: dict) -> None:
    temporary = path.with_suffix(".tmp")
    temporary.write_text(json.dumps(value, ensure_ascii=False), encoding="utf-8")
    os.replace(temporary, path)


def local_addresses() -> list[str]:
    candidates: set[str] = set()
    try:
        candidates.update(a[4][0] for a in socket.getaddrinfo(socket.gethostname(), None, socket.AF_INET))
    except OSError:
        pass
    # Windows may not publish an adapter address through the hostname lookup.
    # A UDP route probe discovers the interface selected for another LAN host
    # without sending a packet or requiring external network access.
    probe = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        probe.connect(("192.0.2.1", 9))
        candidates.add(probe.getsockname()[0])
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
    return sorted(set(valid), key=lambda value: (not ipaddress.IPv4Address(value).is_private, value))


def validate_command(value: dict) -> dict:
    if not isinstance(value, dict) or value.get("action") not in {"start", "stop", "settings"}:
        raise ValueError("无效的操作")
    settings = value.get("settings", {})
    if not isinstance(settings, dict):
        raise ValueError("设置格式错误")
    choices = {"quality": {"smooth", "standard", "high"}, "connection_mode": {"lan", "usb"}}
    result = {}
    for key, setting in settings.items():
        if key in choices and isinstance(setting, str) and setting in choices[key]:
            result[key] = setting
        elif key == "computer_audio" and type(setting) is bool:
            result[key] = setting
        else:
            raise ValueError("不支持的设置")
    return {"action": value["action"], "settings": result}


class DockServer(ThreadingHTTPServer):
    daemon_threads = True

    def __init__(self, directory: Path, port: int):
        self.directory = directory
        self.token = secrets.token_urlsafe(32)
        self.command_lock = threading.Lock()
        self.last_bridge = {}
        self.addresses = local_addresses()
        super().__init__(("127.0.0.1", port), Handler)
        self.origin = f"http://127.0.0.1:{self.server_port}"

    def status(self) -> dict:
        bridge = read_json(self.directory / "applelive-bridge.json")
        if bridge.get("updated_at", 0) >= self.last_bridge.get("updated_at", 0) and bridge:
            self.last_bridge = bridge
        else:
            bridge = self.last_bridge
        sender = read_json(self.directory / "applelive-status.json")
        ready = 0 <= time.time() - bridge.get("updated_at", 0) < 8
        if not 0 <= time.time() - sender.get("updated_at", 0) < 6:
            sender = {"state": "stopped", "clients": 0, "usb_clients": 0}
            if ready and bridge.get("sender_state") in {"starting", "stopping", "error"}:
                sender["state"] = bridge["sender_state"]
                if sender["state"] == "error":
                    sender["error"] = bridge.get("status_text", "发送器启动失败")
        pending = read_json(self.directory / "applelive-command.json")
        if pending.get("action") == "stop" and sender.get("state") in {"starting", "running"}:
            sender["state"] = "stopping"
        port = bridge.get("settings", {}).get("port", 8765)
        return {"ready": ready, "sender": sender, "bridge": bridge,
                "addresses": self.addresses, "token": self.token, "pending": bool(pending),
                "phone_plugin": {"available": plugin_path(self.directory).is_file(), "port": port,
                    "lan_ready": sender.get("connection_mode") == "lan" and sender.get("state") == "running"}}

    def request_firewall_access(self) -> None:
        if os.name != "nt":
            raise OSError("Windows firewall setup is only available on Windows")
        script = self.directory / "setup_lan.ps1"
        if not script.is_file():
            raise OSError("Missing setup_lan.ps1")
        port = int(self.status()["phone_plugin"]["port"])
        arguments = f'-NoProfile -ExecutionPolicy Bypass -File "{script}" -VideoPort {port}'
        import ctypes
        shell_execute = ctypes.windll.shell32.ShellExecuteW
        shell_execute.restype = ctypes.c_void_p
        result = shell_execute(
            None, "runas", "powershell.exe", arguments, str(self.directory), 0)
        if not result or result <= 32:
            raise OSError(f"Could not open Windows firewall setup ({result})")


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
        if url.path in {"/api/phone-plugin", "/api/phone-qr"}:
            host = parse_qs(url.query).get("host", [""])[0]
            if host not in self.server.addresses:
                self.json_reply(400, {"error": "请选择本机局域网地址"})
                return
            status = self.server.status()
            try:
                name = download_name(host, int(status["phone_plugin"]["port"]))
                body = plugin_path(self.server.directory).read_bytes()
            except (ValueError, TypeError):
                self.json_reply(400, {"error": "电脑地址或端口无效"})
                return
            except OSError:
                self.json_reply(404, {"error": "手机插件文件缺失，请更新完整 OBS 插件包"})
                return
            if url.path == "/api/phone-plugin":
                self.reply(200, body, "application/octet-stream", name)
            elif not status["phone_plugin"]["lan_ready"]:
                self.json_reply(409, {"error": "请先在电脑选择局域网并开始传输"})
            else:
                import qrcode
                output = BytesIO()
                qrcode.make(download_url(host, int(status["phone_plugin"]["port"]))).save(output, format="PNG")
                self.reply(200, output.getvalue(), "image/png")
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
            status = self.server.status()
            if not status["ready"]:
                self.json_reply(503, {"error": "请在 OBS 工具 → 脚本中加载 AppleLive.lua"})
                return
            if status["pending"]:
                self.json_reply(409, {"error": "上一项操作正在处理，请稍候"})
                return
            if command["settings"] and status["sender"].get("state") in {"running", "starting", "stopping"}:
                self.json_reply(409, {"error": "请先停止传输，再调整设置"})
                return
            command.update(id=secrets.token_hex(8), created_at=time.time())
            atomic_json(self.server.directory / "applelive-command.json", command)
        self.json_reply(202, {"id": command["id"]})


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--directory", type=Path, required=True)
    parser.add_argument("--port", type=int, default=18765)
    parser.add_argument("--obs-pid", type=int, default=0)
    args = parser.parse_args()
    try:
        server = DockServer(args.directory.resolve(), args.port)
    except OSError:
        return  # An already-running dock owns this loopback port.
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
