"""Real MediaMTX smoke test with H.264/AAC publish and RTSP pull."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import time
import tempfile
from urllib.request import urlopen

from stream_server import StreamServer
from sender import stop_process_tree


def test_user_writable_runtime_directory():
    with tempfile.TemporaryDirectory() as temp:
        old = os.environ.get("LOCALAPPDATA")
        os.environ["LOCALAPPDATA"] = temp
        try:
            server = StreamServer(Path(temp) / "read-only-plugin")
            assert server.runtime_directory == Path(temp) / "AppleLive"
        finally:
            if old is None:
                os.environ.pop("LOCALAPPDATA", None)
            else:
                os.environ["LOCALAPPDATA"] = old


def main():
    test_user_writable_runtime_directory()
    ffmpeg = shutil.which("ffmpeg")
    if not ffmpeg:
        raise RuntimeError("FFmpeg required for the streaming integration test")
    server = StreamServer()
    stream_path = f"live/applelive-test-{os.getpid()}"
    rtmp_url = f"rtmp://127.0.0.1:1935/{stream_path}"
    publisher = None
    try:
        if not server.start():
            raise RuntimeError("Place the existing MediaMTX in obs-plugin/server first")
        fixture = Path(__file__).resolve().parents[1] / "ios-injector/tests/fixture.mp4"
        publisher = subprocess.Popen([ffmpeg, "-hide_banner", "-loglevel", "error", "-re", "-stream_loop", "-1", "-i", str(fixture),
            "-c", "copy", "-flush_packets", "1", "-f", "flv", rtmp_url], stdout=subprocess.DEVNULL, stderr=subprocess.PIPE,
            creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0))
        for _ in range(50):
            with urlopen("http://127.0.0.1:9997/v3/paths/list", timeout=1) as response:
                paths = json.load(response)["items"]
            if any(path.get("name") == stream_path and path.get("ready") for path in paths): break
            time.sleep(0.1)
        else: raise RuntimeError("Publisher did not become ready")
        if publisher.poll() is not None:
            raise RuntimeError(publisher.stderr.read().decode("utf-8", "replace"))
        pulled = subprocess.run([ffmpeg, "-hide_banner", "-loglevel", "error", "-rtsp_transport", "tcp", "-i",
            f"rtsp://127.0.0.1:8554/{stream_path}", "-t", "1", "-map", "0:v:0", "-map", "0:a:0", "-f", "null", "-"],
            capture_output=True, timeout=12, creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0))
        if pulled.returncode:
            raise RuntimeError(pulled.stderr.decode("utf-8", "replace"))
        print("MediaMTX H.264/AAC RTMP publish and RTSP pull passed")
    finally:
        if publisher:
            stop_process_tree(publisher)
            publisher.communicate(timeout=3)
        server.stop()


if __name__ == "__main__": main()
