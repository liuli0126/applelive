"""Build and serve a small LAN APT source for the verified rootless service."""

import argparse
import bz2
from datetime import datetime, timezone
from email.utils import format_datetime
import gzip
import hashlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import importlib
import json
from pathlib import Path
import re
import shutil
from urllib.parse import unquote, urlsplit


def build(package: Path, relink: Path, output: Path):
    verifier = importlib.import_module('verify-uvc-service')
    members = verifier.ar_members(package.read_bytes())
    assert members['debian-binary'] == b'2.0\n'
    control = verifier.tar_members(next(data for name, data in members.items() if name.startswith('control.tar')))
    text = control['control'][1].decode('utf-8').strip()
    fields = dict(line.split(': ', 1) for line in text.splitlines() if ': ' in line and not line.startswith(' '))
    assert fields['Package'] == 'com.applelive.uvchost'
    assert fields['Architecture'] == 'iphoneos-arm64'
    version = fields['Version']
    assert re.fullmatch(r'[0-9A-Za-z.+~-]+', version)
    filename = f'pool/com.applelive.uvchost_{version}_iphoneos-arm64.deb'
    output.mkdir(parents=True, exist_ok=True)
    (output / 'pool').mkdir(exist_ok=True)
    shutil.copyfile(package, output / filename)
    shutil.copyfile(relink, output / 'AppleLive-relink.tar.gz')
    binary = (output / filename).read_bytes()
    checksum = hashlib.sha256(binary).hexdigest()
    index = (text + '\n'
             + f'Filename: {filename}\nSize: {len(binary)}\n'
             + f'MD5sum: {hashlib.md5(binary).hexdigest()}\n'
             + f'SHA256: {checksum}\n\n').encode('utf-8')
    indexes = {'Packages': index, 'Packages.gz': gzip.compress(index, mtime=0),
               'Packages.bz2': bz2.compress(index)}
    for name, data in indexes.items():
        (output / name).write_bytes(data)
    release = ('Origin: AppleLive Local\nLabel: AppleLive USB Service\n'
               'Suite: stable\nCodename: applelive\nArchitectures: iphoneos-arm64\n'
               'Description: AppleLive local phone service installation\n'
               + f'Date: {format_datetime(datetime.now(timezone.utc), usegmt=True)}\n')
    for label, algorithm in [('MD5Sum', 'md5'), ('SHA256', 'sha256')]:
        release += label + ':\n'
        for name, data in indexes.items():
            release += f' {hashlib.new(algorithm, data).hexdigest()} {len(data)} {name}\n'
    (output / 'Release').write_text(release, encoding='ascii', newline='\n')
    # A plain status page, with source/relink materials available alongside the deb.
    page = ('<!doctype html><meta charset="utf-8"><meta name="viewport" content="width=device-width">'
            '<title>AppleLive 软件源</title><h1>AppleLive 软件源已启动</h1>'
            f'<p>采集服务 {version}。请在 Sileo 的“软件源”中添加当前网址，再搜索 AppleLive USB Capture Service 安装。</p>'
            '<p>手机与电脑需在同一局域网，安装期间保持电脑开启。</p>'
            '<p><a href="AppleLive-relink.tar.gz">配套开源许可、源码和重链接资料</a></p>')
    (output / 'index.html').write_text(page, encoding='utf-8')
    files = ['index.html', 'Release', *indexes, filename, 'AppleLive-relink.tar.gz']
    manifest = {'package': fields['Package'], 'version': version, 'sha256': checksum,
                'files': files}
    (output / 'manifest.json').write_text(json.dumps(manifest, indent=2), encoding='utf-8')
    print(json.dumps({'version': version, 'sha256': checksum, 'files': files}), flush=True)


def make_server(root: Path, bind: str, port: int):
    manifest = json.loads((root / 'manifest.json').read_text(encoding='utf-8'))
    allowed = set(manifest['files'])

    class Handler(BaseHTTPRequestHandler):
        def do_HEAD(self):
            self.respond(head=True)

        def do_GET(self):
            self.respond(head=False)

        def respond(self, head):
            name = unquote(urlsplit(self.path).path).lstrip('/') or 'index.html'
            if name not in allowed:
                self.send_error(404)
                return
            path = (root / name).resolve()
            if not path.is_relative_to(root) or not path.is_file():
                self.send_error(404)
                return
            with path.open('rb') as stream:
                self.send_response(200)
                self.send_header('Content-Type', 'text/html; charset=utf-8' if name == 'index.html' else 'application/octet-stream')
                self.send_header('Content-Length', str(path.stat().st_size))
                self.send_header('Cache-Control', 'no-cache')
                self.end_headers()
                if not head:
                    try:
                        shutil.copyfileobj(stream, self.wfile, 128 * 1024)
                    except (BrokenPipeError, ConnectionResetError):
                        pass

    return ThreadingHTTPServer((bind, port), Handler)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest='command', required=True)
    build_parser = sub.add_parser('build')
    build_parser.add_argument('--package', required=True, type=Path)
    build_parser.add_argument('--relink', required=True, type=Path)
    build_parser.add_argument('--output', required=True, type=Path)
    serve_parser = sub.add_parser('serve')
    serve_parser.add_argument('--root', required=True, type=Path)
    serve_parser.add_argument('--bind', default='127.0.0.1')
    serve_parser.add_argument('--port', default=18766, type=int)
    args = parser.parse_args()
    if args.command == 'build':
        build(args.package.resolve(), args.relink.resolve(), args.output.resolve())
    else:
        with make_server(args.root.resolve(), args.bind, args.port) as server:
            print(f'AppleLive Sileo source: http://{args.bind}:{server.server_port}/', flush=True)
            server.serve_forever()
