"""Small local OBS WebSocket 5 client for stream settings and controls."""
from __future__ import annotations

import base64
import hashlib
import json
import os
from pathlib import Path
import secrets

from websockets.sync.client import connect
from websockets.exceptions import WebSocketException


class OBSConnectionError(RuntimeError):
    def __init__(self, message: str, code: int | None = None):
        super().__init__(message)
        self.code = code


class OBSClient:
    def __init__(self, plugin_directory: Path):
        roots = [plugin_directory.parents[2] / "config" / "obs-studio"]
        if os.environ.get("APPDATA"):
            roots.append(Path(os.environ["APPDATA"]) / "obs-studio")
        self.config = {}
        for root in roots:
            path = root / "plugin_config" / "obs-websocket" / "config.json"
            try:
                self.config = json.loads(path.read_text(encoding="utf-8-sig"))
                break
            except (OSError, ValueError):
                pass
        self.port = int(self.config.get("server_port", 4455))
        self.socket = None

    def __enter__(self):
        if self.config.get("server_enabled") is False:
            raise OBSConnectionError("请在 OBS 工具 → WebSocket 服务器设置中启用服务器")
        try:
            self.socket = connect(f"ws://127.0.0.1:{self.port}", open_timeout=2, close_timeout=0.2)
            hello = json.loads(self.socket.recv(timeout=2))
            if hello.get("op") != 0:
                raise OBSConnectionError("OBS WebSocket 握手失败")
            identify = {"rpcVersion": 1, "eventSubscriptions": 0}
            auth = hello["d"].get("authentication")
            if auth:
                password = self.config.get("server_password", "")
                if not password:
                    raise OBSConnectionError("OBS WebSocket 已设密码，但本机配置中找不到密码")
                secret = base64.b64encode(hashlib.sha256((password + auth["salt"]).encode()).digest()).decode()
                identify["authentication"] = base64.b64encode(
                    hashlib.sha256((secret + auth["challenge"]).encode()).digest()).decode()
            self.socket.send(json.dumps({"op": 1, "d": identify}))
            response = json.loads(self.socket.recv(timeout=2))
            if response.get("op") != 2:
                raise OBSConnectionError("OBS WebSocket 认证失败")
            return self
        except OBSConnectionError:
            self.__exit__(None, None, None)
            raise
        except (OSError, TimeoutError, ValueError, KeyError, WebSocketException) as error:
            self.__exit__(None, None, None)
            raise OBSConnectionError("无法连接 OBS WebSocket，请确认 OBS 正在运行且服务器已启用") from error

    def __exit__(self, *_args):
        if self.socket:
            self.socket.close()
            self.socket = None

    def request(self, name: str, data: dict | None = None) -> dict:
        request_id = secrets.token_hex(8)
        try:
            self.socket.send(json.dumps({"op": 6, "d": {
                "requestType": name, "requestId": request_id, "requestData": data or {}}}))
            response = json.loads(self.socket.recv(timeout=3))
        except (OSError, TimeoutError, ValueError, WebSocketException) as error:
            raise OBSConnectionError("OBS WebSocket 连接中断") from error
        payload = response.get("d", {})
        if response.get("op") != 7 or payload.get("requestId") != request_id:
            raise OBSConnectionError("OBS WebSocket 响应无效")
        status = payload.get("requestStatus", {})
        if not status.get("result"):
            code = status.get("code")
            comment = status.get("comment", "OBS 拒绝了操作")
            if code == 207 or comment == "OBS is not ready to perform the request.":
                comment = "OBS 尚未完成启动，请先完成或关闭自动配置向导和设置窗口"
            raise OBSConnectionError(comment, code)
        return payload.get("responseData", {})

    def stream_state(self) -> dict:
        stream = self.request("GetStreamStatus")
        try:
            service = self.request("GetStreamServiceSettings")
        except OBSConnectionError as error:
            if error.code != 207:
                raise
            service = {}
        settings = service.get("streamServiceSettings", {})
        server = settings.get("server", "")
        configured = service.get("streamServiceType") == "rtmp_custom" and \
            server.startswith("rtmp://") and server.endswith(":1935/live") and \
            settings.get("key") == "applelive"
        return {"stream_active": bool(stream.get("outputActive")),
                "stream_configured": configured, "stream_server": server if configured else ""}

    def configure(self, host: str) -> None:
        if self.request("GetStreamStatus").get("outputActive"):
            raise OBSConnectionError("请先停止 OBS 当前直播")
        self.request("SetStreamServiceSettings", {"streamServiceType": "rtmp_custom",
            "streamServiceSettings": {"server": f"rtmp://{host}:1935/live", "key": "applelive", "use_auth": False}})

    def start(self) -> None:
        if not self.stream_state()["stream_configured"]:
            raise OBSConnectionError("请先点击获取推流码")
        if not self.request("GetStreamStatus").get("outputActive"):
            self.request("StartStream")

    def stop(self) -> None:
        state = self.stream_state()
        if state["stream_active"]:
            if not state["stream_configured"]:
                raise OBSConnectionError("OBS 正在向其他地址直播，请在 OBS 中停止")
            self.request("StopStream")
