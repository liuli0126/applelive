"""Exercise the actual loopback server with a simulated raw UVC source."""
import json
from pathlib import Path
import socket
import struct
import subprocess
import sys
import tempfile
import time

def exact(sock, size):
    chunks = bytearray()
    while len(chunks) < size:
        part = sock.recv(size - len(chunks))
        if not part:
            raise EOFError('closed')
        chunks.extend(part)
    return bytes(chunks)

def read(sock):
    length, = struct.unpack('!I', exact(sock, 4))
    assert 1 <= length <= 8 * 1024 * 1024 + 32
    payload = exact(sock, length)
    return chr(payload[0]), payload[1:]

def command(sock, obj, fragmented=False):
    body = b'C' + json.dumps(obj).encode()
    wire = struct.pack('!I', len(body)) + body
    if fragmented:
        for size in (1, 2, 1, 3):
            sock.sendall(wire[:size]); wire = wire[size:];time.sleep(.015)
    sock.sendall(wire)

def connect(port):
    return socket.create_connection(('127.0.0.1', port), timeout=3)

with tempfile.TemporaryDirectory(prefix='applelive-uvc-service-') as directory:
    root = Path(directory)
    with socket.socket() as probe:
        probe.bind(('127.0.0.1', 0));port = probe.getsockname()[1]
    process = subprocess.Popen([sys.argv[1], str(port), directory], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    token = ''
    try:
        for _ in range(100):
            if (root / 'service-pid').exists(): break
            if process.poll() is not None: raise RuntimeError(process.communicate())
            time.sleep(.03)
        token = (root / 'connection-token').read_text()
        assert len(token) == 64 and (root / 'connection-token').stat().st_mode & 0o777 == 0o600
        with connect(port) as sock:
            command(sock, {'command':'start','version':1,'token':'0'*64})
            kind, data = read(sock)
            assert kind == 'S' and json.loads(data)['code'] == 401
            assert 'diagnostic' not in json.loads(data) or not json.loads(data)['diagnostic']
        with connect(port) as sock:
            sock.sendall(struct.pack('!I', 100 * 1024 * 1024) + b'C')
            try: assert sock.recv(1) == b''
            except ConnectionResetError: pass
        with connect(port) as sock:
            command(sock, {'command':'start','version':1,'token':token}, fragmented=True)
            while True:
                kind, data = read(sock)
                if kind == 'V': break
            assert data[:4] == b'UVF1'
            fmt, width, height, stride, length = struct.unpack('!IIIII', data[4:24])
            assert (fmt,width,height,stride,length)==(2,4,2,8,16)
            # Without credit, at most one frame travels over the socket.
            sock.settimeout(.2)
            try:
                while True:
                    kind, _ = read(sock)
                    assert kind != 'V', 'unbounded video without receiver credit'
            except socket.timeout: pass
            sock.settimeout(3)
            for _ in range(3):
                command(sock, {'command':'next'})
                while read(sock)[0] != 'V': pass
        time.sleep(.15)
        subprocess.run([sys.argv[2], str(port), str(root / 'connection-token')], check=True, timeout=15)
    finally:
        process.terminate()
        stdout, stderr = process.communicate(timeout=10)
        assert process.returncode == 0, stderr.decode()
        log = stderr.decode()
        assert log.count('session started') == log.count('session closed') == 3, log
        assert not token or token not in log
    print('PASS authenticated loopback UVC server, fragmentation, oversize rejection, credit bounds and teardown')
