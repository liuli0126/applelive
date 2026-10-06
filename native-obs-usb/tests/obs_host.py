"""Exercise the real libobs ABI and encoder callbacks without starting user OBS.

Usage: python native-obs-usb/tests/obs_host.py OBS_ROOT OUTPUT_DIRECTORY
The second directory receives exact ALUSB frames for the macOS decoder test.
"""
import ctypes as C
import os
from pathlib import Path
import socket
import struct
import sys
import threading
import time

ROOT = Path(__file__).resolve().parents[2]
obsroot, dest = Path(sys.argv[1]).resolve(), Path(sys.argv[2]).resolve()
dest.mkdir(parents=True, exist_ok=True)
binpath = obsroot / "bin/64bit"
dllpath = os.add_dll_directory(str(binpath))
pluginpath = os.add_dll_directory(str(obsroot / "obs-plugins/64bit"))
os.chdir(binpath)
obs = C.CDLL(str(binpath / "obs.dll"))
P, S, U = C.c_void_p, C.c_char_p, C.c_uint32


def api(name, restype, *argtypes):
    f = getattr(obs, name)
    f.restype, f.argtypes = restype, argtypes
    return f


def free_port():
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


control = free_port()
listener = socket.socket()
listener.bind(("127.0.0.1", 0))
listener.listen()
listener.settimeout(15)
os.environ["APPLELIVE_TEST_RELAY_PORT"] = str(listener.getsockname()[1])
os.environ["APPLELIVE_TEST_CONTROL_PORT"] = str(control)


class Video(C.Structure):
    _fields_ = [("graphics", S), ("fps_num", U), ("fps_den", U), ("bw", U),
                ("bh", U), ("ow", U), ("oh", U), ("format", C.c_int),
                ("adapter", U), ("gpu", C.c_bool), ("colorspace", C.c_int),
                ("range", C.c_int), ("scale", C.c_int)]


class Audio(C.Structure):
    _fields_ = [("rate", U), ("speakers", C.c_int)]


def load(name, dll=None):
    module = P()
    path = dll or obsroot / "obs-plugins/64bit" / (name + ".dll")
    # OBS uses LOAD_WITH_ALTERED_SEARCH_PATH; seed its transitive DLLs from
    # the host directory when the executable is Python rather than obs64.exe.
    C.CDLL(str(path))
    assert api("obs_open_module", C.c_int, C.POINTER(P), S, S)(C.byref(module), str(path).encode(),
        str(obsroot / "data/obs-plugins" / name).encode()) == 0, name
    assert api("obs_init_module", C.c_bool, P)(module), name


def command(value):
    with socket.create_connection(("127.0.0.1", control), 8) as client:
        client.sendall(value.encode())
        return client.recv(64).strip()


def exact(client, n):
    result = b""
    while len(result) < n:
        part = client.recv(n - len(result))
        if not part:
            raise EOFError()
        result += part
    return result


captures, errors = [], []


def receive():
    try:
        # Delay the initial greeting, reconnect, then exercise another clean start.
        for session in range(3):
            client, _ = listener.accept()
            with client:
                client.settimeout(5)
                if session == 0:
                    time.sleep(.2)
                    client.setblocking(False)
                    try:
                        assert not client.recv(1), "media sent before phone greeting"
                    except BlockingIOError:
                        pass
                    client.settimeout(5)
                for fragment in (b"AL", b"USB1\r", b"\n"):
                    client.sendall(fragment)
                frames = []
                while sum(p[:4] == b"fram" for p in frames) < 65:
                    size = struct.unpack(">I", exact(client, 4))[0]
                    assert 4 <= size <= 8 * 1024 * 1024
                    frames.append(exact(client, size))
                video = [p for p in frames if p[:4] == b"fram"]
                assert struct.unpack_from("<I", video[0], 8)[0] == 3
                assert all(struct.unpack_from("<I", p, 8)[0] & 2 for p in video)
                audio = [p for p in frames if p[:4] in (b"aacd", b"aaca")]
                assert audio and audio[0][:4] == b"aacd"
                assert sum(p[:4] == b"aaca" for p in audio) > 50
                (dest / f"native-{session}.alusb").write_bytes(b"".join(struct.pack(">I", len(p)) + p for p in frames))
                (dest / f"native-{session}.h264").write_bytes(b"".join(p[20:] for p in video))
                captures.append((len(video), len(audio)))
    except BaseException as e:
        errors.append(e)


assert api("obs_startup", C.c_bool, S, S, P)(b"en-US", str(dest / "config").encode(), None)
api("obs_add_data_path", None, S)(str(obsroot / "data/libobs").encode())
assert api("obs_reset_audio", C.c_bool, C.POINTER(Audio))(C.byref(Audio(48000, 2)))
# VIDEO_FORMAT_NV12=2, VIDEO_CS_709=2, VIDEO_RANGE_PARTIAL=1.
video = Video(b"libobs-d3d11.dll", 30, 1, 640, 360, 640, 360, 2, 0, True, 2, 1, 1)
assert api("obs_reset_video", C.c_int, C.POINTER(Video))(C.byref(video)) == 0
load("obs-x264")
load("obs-ffmpeg")
load("applelive-native-output", ROOT / "obs-plugin/applelive-native-output.dll")
settings = api("obs_data_create", P)()
api("obs_data_set_string", None, P, S, S)(settings, b"local_file", str(ROOT / "ios-injector/tests/fixture.mp4").encode())
for key in (b"is_local_file", b"looping"):
    api("obs_data_set_bool", None, P, S, C.c_bool)(settings, key, True)
source = api("obs_source_create", P, S, S, P, P)(b"ffmpeg_source", b"USB test fixture", settings, None)
assert source
api("obs_data_release", None, P)(settings)
api("obs_set_output_source", None, U, P)(0, source)
worker = threading.Thread(target=receive)
worker.start()
try:
    assert command("start") == b"ok"
    assert command("start") == b"ok", "start must be idempotent"
    worker.join(35)
    assert not worker.is_alive(), "encoder test timed out"
    assert not errors, repr(errors)
    assert len(captures) == 3, captures
    assert command("stop") == b"ok"
    assert command("status") == b"stopped"
    assert command("start") == b"ok", "restart failed"
    assert command("stop") == b"ok"
finally:
    listener.close()
    api("obs_set_output_source", None, U, P)(0, None)
    api("obs_source_release", None, P)(source)
    api("obs_shutdown", None)()
print("PASS real OBS encoding, fragmented greeting, reconnect, start/stop:", captures)
