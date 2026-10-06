"""Loopback-only AppleLive browser dock backed by OBS WebSocket 5."""
from __future__ import annotations

import argparse
import ipaddress
import json
import os
from pathlib import Path
import secrets
import socket
import subprocess
import tempfile
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlsplit

from obs_websocket import OBSClient, OBSConnectionError
from phone_plugin import plugin_path
from stream_server import RTMP_URL, StreamServer

DESKTOP_VERSION = "0.4.3"


def _list_dshow_devices(ffmpeg: Path) -> list[tuple[str, str]]:
    try:
        result = subprocess.run(
            [str(ffmpeg), "-hide_banner", "-list_devices", "true", "-f", "dshow", "-i", "dummy"],
            capture_output=True, timeout=5, check=False,
        )
        output = (result.stdout + result.stderr).decode("utf-8", errors="replace")
        import re
        return [(match.group(1), match.group(2).lower()) for match in re.finditer(
            r'"([^"]+)"\s+\((video|audio|none)\)', output, re.I)]
    except (OSError, subprocess.TimeoutExpired):
        return []


def find_virtual_camera(ffmpeg: Path) -> str:
    """Find the OBS program camera name on this Windows installation.

    OBS calls it ``OBS Virtual Camera`` in a standard install and ``HD
    Camera`` in the customized OBS build used by this project.  Device names
    are localized and can change between OBS versions, so probe DirectShow
    once instead of hard-coding one name.
    """
    candidates = [name for name, kind in _list_dshow_devices(ffmpeg) if kind in {"video", "none"}]
    preferred = ("OBS Virtual Camera", "HD Camera", "OBS-Camera", "OBS Camera")
    for name in preferred:
        if name in candidates:
            return name
    for name in candidates:
        lowered = name.lower()
        if "obs" in lowered and ("camera" in lowered or "cam" in lowered):
            return name
    # Keep the standard name as a useful error message on machines where OBS
    # has not registered its virtual camera yet.
    return preferred[0]


def find_audio_device(ffmpeg: Path) -> str:
    """Prefer a loopback/virtual playback capture device for OBS mixed audio."""
    candidates = [name for name, kind in _list_dshow_devices(ffmpeg) if kind == "audio"]
    preferred = (
        "CABLE Output (VB-Audio Virtual Cable)",
        "VB-Audio Virtual Cable",
        "OBS Audio",
        "Desktop Audio",
    )
    for name in preferred:
        if name in candidates:
            return name
    for name in candidates:
        lowered = name.lower()
        if "cable output" in lowered or "virtual audio" in lowered:
            return name
    return ""


class USBSender:
    def __init__(self, directory: Path):
        self.directory = directory
        runtime_root = Path(os.environ.get("LOCALAPPDATA", tempfile.gettempdir())) / "AppleLive"
        self.status_file = runtime_root / "applelive-usb-status.json"
        self.stop_file = runtime_root / "applelive-usb-stop.flag"
        self.log_file = runtime_root / "applelive-usb.log"
        self.process = None
        self.native_process = None
        self.native_mode = False
        self.native_control_port = 28766
        self.native_relay_port = 28765
        self.input_url = ""
        self.width = 0
        self.height = 0
        self.fps = 30

    def native_available(self) -> bool:
        relay, output = self._native_paths()
        return relay.is_file() and output.is_file()

    def start(self, input_url: str, video_settings: dict | None = None) -> None:
        if self.process and self.process.poll() is None:
            return
        if self.native_process and self.native_process.poll() is None:
            return
        if self.native_available():
            if self._start_native():
                return
            raise OSError("USB 原生模块未就绪。请关闭后重新打开本套 OBS；若仍失败，请查看 OBS 日志中的 AppleLive 错误。")
        sender = self.directory / "AppleLiveSender.exe"
        ffmpeg = self.directory / "ffmpeg.exe"
        if not sender.is_file() or not ffmpeg.is_file():
            raise OSError("USB 组件缺失，请安装完整 AppleLive OBS 插件包")
        self.status_file.parent.mkdir(parents=True, exist_ok=True)
        self.stop_file.unlink(missing_ok=True)
        self.status_file.unlink(missing_ok=True)
        if not input_url:
            raise ValueError("USB 媒体地址为空")
        self.input_url = input_url
        if video_settings:
            width = int(video_settings.get("outputWidth") or video_settings.get("baseWidth") or 0)
            height = int(video_settings.get("outputHeight") or video_settings.get("baseHeight") or 0)
            fps_num = int(video_settings.get("fpsNumerator") or 0)
            fps_den = int(video_settings.get("fpsDenominator") or 1)
            if width >= 320 and height >= 240 and width % 2 == 0 and height % 2 == 0:
                self.width, self.height = width, height
            if 1 <= fps_num <= 60 * fps_den:
                self.fps = max(1, min(60, round(fps_num / fps_den)))
        command = [
            str(sender), "--connection-mode", "usb", "--port", "0",
            "--input-url", input_url, "--ffmpeg", str(ffmpeg),
            "--width", str(self.width or 1920), "--height", str(self.height or 1080),
            "--fps", str(self.fps),
            "--status-file", str(self.status_file), "--stop-file", str(self.stop_file),
            "--log-file", str(self.log_file),
        ]
        self.process = subprocess.Popen(
            command, cwd=self.directory, stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
            creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0),
        )

    def _native_paths(self) -> tuple[Path, Path]:
        relay = self.directory / "AppleLiveUsbRelay.exe"
        obs_root = self.directory.parents[2] if len(self.directory.parents) > 2 else self.directory
        output = obs_root / "obs-plugins" / "64bit" / "applelive-native-output.dll"
        return relay, output

    def _native_command(self, command: str) -> str:
        try:
            with socket.create_connection(("127.0.0.1", self.native_control_port), timeout=1.5) as connection:
                connection.sendall(command.encode("ascii"))
                return connection.recv(64).decode("ascii", errors="replace").strip()
        except OSError:
            return ""

    def _start_native(self) -> bool:
        relay, output = self._native_paths()
        if not relay.is_file() or not output.is_file():
            return False
        self.status_file.parent.mkdir(parents=True, exist_ok=True)
        self.stop_file.unlink(missing_ok=True)
        self.status_file.unlink(missing_ok=True)
        command = [str(relay), "--listen", str(self.native_relay_port),
                   "--status-file", str(self.status_file)]
        self.native_process = subprocess.Popen(
            command, cwd=self.directory, stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
            creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0),
        )
        for _ in range(20):
            if self.native_process.poll() is not None:
                self.native_process = None
                return False
            if self._native_command("start") == "ok":
                self.native_mode = True
                self.input_url = "OBS native encoded output"
                return True
            time.sleep(0.1)
        self._stop_native()
        return False

    def _stop_native(self) -> None:
        if self.native_mode:
            self._native_command("stop")
        process, self.native_process = self.native_process, None
        self.native_mode = False
        if process and process.poll() is None:
            try:
                process.terminate()
                process.wait(timeout=2)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(timeout=2)

    def stop(self) -> None:
        if self.native_process:
            self._stop_native()
            return
        process, self.process = self.process, None
        if not process or process.poll() is not None:
            return
        self.stop_file.parent.mkdir(parents=True, exist_ok=True)
        self.stop_file.write_text("stop", encoding="ascii")
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            process.terminate()
            try:
                process.wait(timeout=2)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(timeout=2)

    def status(self) -> dict:
        running = bool((self.process and self.process.poll() is None) or
                       (self.native_process and self.native_process.poll() is None))
        value = {"state": "stopped", "usb_clients": 0, "error": "", "running": running,
                 "input_url": self.input_url, "video_device": "OBS native encoded output" if self.native_mode else "OBS local RTMP",
                 "audio_device": "OBS native encoded track" if self.native_mode else "OBS AAC track",
                 "native": self.native_mode}
        try:
            saved = json.loads(self.status_file.read_text(encoding="utf-8"))
            if isinstance(saved, dict) and (self.process is not None or self.native_process is not None):
                value.update({key: saved.get(key, value[key]) for key in ("state", "usb_clients", "error")})
        except (OSError, ValueError, TypeError):
            pass
        if not running and value["state"] not in {"error", "stopped"}:
            value["state"] = "stopped"
        return value


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
    if set(value) - {"action", "host", "mode"}:
        raise ValueError("不支持的设置")
    host = value.get("host", "")
    mode = value.get("mode", "")
    if value["action"] == "configure_stream":
        if mode not in {"lan", "usb"}:
            raise ValueError("请选择局域网或 USB 数据线")
        if mode == "lan":
            try:
                host = str(ipaddress.IPv4Address(host))
            except (ipaddress.AddressValueError, TypeError):
                raise ValueError("电脑局域网 IP 无效") from None
        else:
            host = "127.0.0.1"
    elif host or mode:
        raise ValueError("此操作不需要 IP")
    return {"action": value["action"], "host": host, "mode": mode}


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
        self.usb_sender = USBSender(directory)
        self.usb_stream_owned = False
        self.native_stream_owned = False
        self.stream_error = ""
        self.firewall_pending = False
        self.firewall_error = ""

    def server_close(self):
        self.usb_sender.stop()
        self.native_stream_owned = False
        if self.usb_stream_owned:
            try:
                with OBSClient(self.directory) as client:
                    client.stop()
            except OBSConnectionError:
                pass
            self.usb_stream_owned = False
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
                "usb": self.usb_sender.status(),
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
            if command["action"] == "configure_stream" and command["mode"] == "lan" and command["host"] not in self.server.addresses:
                self.json_reply(400, {"error": "请选择这台电脑的局域网 IP"})
                return
            try:
                with OBSClient(self.server.directory) as client:
                    if command["action"] == "configure_stream":
                        self.server.usb_sender.stop()
                        if command["mode"] == "usb":
                            if self.server.usb_sender.native_available():
                                # The native output owns OBS's encoded packet
                                # path. It talks to the relay directly and
                                # never starts the LAN RTMP stream.
                                self.server.usb_sender.start("")
                                self.server.native_stream_owned = True
                                self.server.usb_stream_owned = False
                            else:
                                # Tested fallback for packages built before
                                # the native OBS SDK is available.
                                self.server.ensure_stream_server()
                                client.configure("127.0.0.1")
                                client.start()
                                self.server.usb_stream_owned = True
                                self.server.native_stream_owned = False
                                self.server.usb_sender.start(RTMP_URL, client.video_settings())
                        else:
                            if self.server.usb_stream_owned:
                                client.stop()
                                self.server.usb_stream_owned = False
                            if self.server.native_stream_owned:
                                self.server.native_stream_owned = False
                            client.configure(command["host"])
                            self.server.ensure_stream_server()
                    elif command["action"] == "start_stream":
                        mode = client.stream_state().get("stream_mode")
                        if ((self.server.usb_sender.process and self.server.usb_sender.process.poll() is None) or
                                (self.server.usb_sender.native_process and self.server.usb_sender.native_process.poll() is None)):
                            mode = "usb"
                        if mode == "usb":
                            if self.server.usb_sender.native_available():
                                self.server.usb_sender.start("")
                                self.server.native_stream_owned = True
                            else:
                                self.server.ensure_stream_server()
                                if client.stream_state().get("stream_server") != "rtmp://127.0.0.1:1935/live":
                                    client.configure("127.0.0.1")
                                if not client.stream_state().get("stream_active"):
                                    client.start()
                                self.server.usb_stream_owned = True
                                self.server.usb_sender.start(RTMP_URL, client.video_settings())
                        else:
                            self.server.ensure_stream_server()
                            client.start()
                    elif command["action"] == "stop_stream":
                        self.server.usb_sender.stop()
                        if self.server.usb_stream_owned:
                            client.stop()
                            self.server.usb_stream_owned = False
                        elif self.server.native_stream_owned:
                            self.server.native_stream_owned = False
                        else:
                            client.stop()
                        self.server.stop_stream_server()
            except (OBSConnectionError, OSError, RuntimeError, ValueError) as error:
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
