"""Verify the production encoder sends Annex-B and an audible standard stream."""
from argparse import Namespace
from pathlib import Path
import math
import shutil
import struct
import subprocess
import threading
import time
import json
from urllib.request import urlopen

from sender import video_command, AnnexBParser
from stream_server import StreamServer, RTMP_URL


def main():
    ffmpeg = shutil.which("ffmpeg")
    fixture = str(Path(__file__).resolve().parents[1] / "ios-injector/tests/fixture.mp4")
    args = Namespace(ffmpeg=ffmpeg, fps=25, width=320, height=240, video_device="fixture", audio_device="fixture",
                     bitrate_kbps=600, encoder="x264", encoder_preset="veryfast", rtmp_url=RTMP_URL)
    command = video_command(args)
    # Use a deterministic file for the two capture inputs while preserving the output graph.
    end = command.index("-vf")
    command[command.index("-f"):end] = ["-re", "-stream_loop", "-1", "-i", fixture, "-re", "-stream_loop", "-1", "-i", fixture]
    server = StreamServer(); process = None; types = []
    try:
        if not server.start(): raise RuntimeError("MediaMTX is required")
        process = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                   creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0))
        def drain():
            parser = AnnexBParser()
            for chunk in iter(lambda: process.stdout.read1(65536), b""):
                for nal in parser.feed(chunk):
                    offset = 4 if nal.startswith(b'\0\0\0\1') else 3
                    types.append(nal[offset] & 31)
        thread = threading.Thread(target=drain, daemon=True); thread.start()
        for _ in range(80):
            with urlopen('http://127.0.0.1:9997/v3/paths/list', timeout=1) as response:
                paths = json.load(response)['items']
            if any(p.get('name') == 'live/applelive' and p.get('ready') for p in paths): break
            if process.poll() is not None: raise RuntimeError('Encoder exited')
            time.sleep(0.1)
        else: raise RuntimeError('Encoder did not publish a stream')
        audio = subprocess.run([ffmpeg, "-hide_banner", "-loglevel", "error", "-rtsp_transport", "tcp", "-i",
            "rtsp://127.0.0.1:8554/live/applelive", "-t", "0.5", "-map", "0:a:0", "-ac", "1", "-ar", "48000", "-f", "f32le", "pipe:1"],
            capture_output=True, timeout=12, creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0))
        if audio.returncode: raise RuntimeError(audio.stderr.decode("utf-8", "replace"))
        samples = struct.unpack('<' + 'f' * (len(audio.stdout) // 4), audio.stdout)
        if not samples or math.sqrt(sum(s * s for s in samples) / len(samples)) < 0.01:
            raise RuntimeError("Published audio is silent")
        if not {5, 7, 8} <= set(types): raise RuntimeError("Annex-B output missing IDR/SPS/PPS")
        print("Production H.264 tee and audible AAC stream passed")
    finally:
        if process:
            process.terminate(); process.wait(timeout=4)
            thread.join(timeout=2)
            error = process.stderr.read().decode("utf-8", "replace")
            if error: print(error[-2000:])
        server.stop()


if __name__ == '__main__': main()
