"""Update plugins in an existing AppleLive service/full DEB, preserving its installer."""

from __future__ import annotations

import argparse
import hashlib
import importlib.util
import json
from pathlib import Path
import re
import struct
import tempfile

PLUGIN_PATH = 'var/jb/Library/AppleLive/AppleLive.dylib'
AUTOMATIC_PLUGIN_PATH = 'var/jb/Library/MobileSubstrate/DynamicLibraries/AppleLive.dylib'
PACKAGE_PLUGINS = {
    'com.applelive.uvchost': (PLUGIN_PATH,),
    'com.applelive.full': (PLUGIN_PATH, AUTOMATIC_PLUGIN_PATH),
}


def load(name, filename):
    spec = importlib.util.spec_from_file_location(name, Path(__file__).with_name(filename))
    if spec is None or spec.loader is None:
        raise RuntimeError(f'Cannot load {filename}')
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def require(condition, message):
    if not condition:
        raise ValueError(message)


def normalized(name):
    return name.removeprefix('./').rstrip('/')


def metadata(info):
    return (info.name, info.mode, info.uid, info.gid, info.uname, info.gname,
            info.mtime, info.type, info.linkname, info.devmajor, info.devminor, info.pax_headers)


def update(source: Path, plugin: Path, destination: Path, revision: int):
    source, plugin, destination = source.resolve(), plugin.resolve(), destination.resolve()
    require(source != destination, 'Build to a separate file; verify before replacing the original')
    require(revision > 0, 'The Debian revision must be positive')
    binary_verifier = load('binary_verifier', 'verify-injector-dylib.py')
    package_verifier = load('package_verifier', 'verify-uvc-service.py')
    archive_tools = load('archive_tools', 'repack-deb-gzip.py')
    binary_verifier.verify(plugin)
    binary = plugin.read_bytes()
    # Reject an older valid Mach-O accidentally selected for this repair.
    for index in range(struct.unpack_from('>I', binary, 4)[0]):
        _, subtype, offset, size, _ = struct.unpack_from('>IIIII', binary, 8 + index * 20)
        body = binary[offset:offset + size]
        for marker in (b'hasFrameReceivedWithin:', b'markInterrupted', b'isVideoReplacementActive',
                       b'renderVideoIntoSample:pixelBuffer:',
                       b'retaining last video frame during transport recovery',
                       b'ALInjectedScreenMonitor', b'observeMatch:usable:', b'sendPendingAlert'):
            require(marker in body, f'Missing continuity/monitor implementation in slice {subtype:#x}: {marker!r}')

    original_bytes = source.read_bytes()
    members = package_verifier.ar_members(original_bytes)
    require(members.get('debian-binary') == b'2.0\n', 'Expected Debian format 2.0')
    control_name = next(name for name in members if name.startswith('control.tar'))
    data_name = next(name for name in members if name.startswith('data.tar'))
    require(set(members) == {'debian-binary', control_name, data_name}, 'Unexpected ar members')
    control = archive_tools.read_tar(members[control_name])
    payload = archive_tools.read_tar(members[data_name])
    # Reject duplicate/unsafe paths and unexpected ownership before repacking.
    parsed_control = package_verifier.tar_members(members[control_name])
    package_verifier.tar_members(members[data_name])
    require(set(parsed_control) == {'control', 'postinst', 'prerm', 'postrm'},
            'Unexpected control files; checksums or additional scripts require review')
    old_control = parsed_control['control'][1]
    fields = dict(line.split(': ', 1) for line in old_control.decode().splitlines() if ': ' in line)
    package_id = fields.get('Package')
    require(package_id in PACKAGE_PLUGINS, 'Wrong existing package identity')
    plugin_paths = PACKAGE_PLUGINS[package_id]
    require(fields.get('Architecture') == 'iphoneos-arm64', 'Wrong existing package architecture')
    full = package_id == 'com.applelive.full'
    pattern = r'(\d+(?:\.\d+)+)-usb(\d+)' if full else r'(\d+(?:\.\d+)+)(?:-(\d+))?'
    match = re.fullmatch(pattern, fields['Version'])
    require(match is not None, 'Unsupported existing version format')
    require(revision > int(match[2] or 0), 'Revision must increase for an existing installation')
    version = f'{match[1]}-{"usb" if full else ""}{revision}'
    new_control = re.sub(rb'(?m)^Version: [^\r\n]+', b'Version: ' + version.encode(), old_control)
    for path in plugin_paths:
        require(sum(normalized(info.name) == path for info, _ in payload) == 1,
                f'Expected exactly one embedded plugin at {path}')
    new_payload = [(info, binary if normalized(info.name) in plugin_paths else body)
                   for info, body in payload]
    new_controls = [(info, new_control if normalized(info.name) == 'control' else body)
                    for info, body in control]
    destination.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(prefix='applelive-plugin-', suffix='.deb', delete=False,
                                     dir=destination.parent) as pending_file:
        pending = Path(pending_file.name)
    try:
        archive_tools.write_ar(pending, [
            ('debian-binary', members['debian-binary']),
            ('control.tar.gz', archive_tools.gzip_tar(new_controls)),
            ('data.tar.gz', archive_tools.gzip_tar(new_payload)),
        ])
        rebuilt = package_verifier.ar_members(pending.read_bytes())
        for old_entries, name, allowed, replacement in (
            (control, 'control.tar.gz', ('control',), new_control),
            (payload, 'data.tar.gz', plugin_paths, binary),
        ):
            updated_entries = archive_tools.read_tar(rebuilt[name])
            require(len(old_entries) == len(updated_entries), 'Package entry count changed')
            for (before_info, before), (after_info, after) in zip(old_entries, updated_entries):
                require(metadata(before_info) == metadata(after_info), 'Package path/permissions changed')
                expected = replacement if normalized(before_info.name) in allowed else before
                require(after == expected, f'Unexpected payload change: {before_info.name}')
        package_verifier.verify(pending, plugin, expected_package=package_id)
        result = {
            'package': fields['Package'], 'previous_version': fields['Version'], 'version': version,
            'source_deb_sha256': hashlib.sha256(original_bytes).hexdigest(),
            'dylib_sha256': hashlib.sha256(binary).hexdigest(),
            'deb_sha256': hashlib.sha256(pending.read_bytes()).hexdigest(),
            'deb_bytes': pending.stat().st_size,
            'control_entries': len(control), 'payload_entries': len(payload),
            'automatic_injection': full,
            'only_changes': ['control/Version', *plugin_paths],
        }
        pending.replace(destination)
        print(json.dumps(result, ensure_ascii=False, indent=2))
        return result
    finally:
        pending.unlink(missing_ok=True)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('source', type=Path)
    parser.add_argument('plugin', type=Path)
    parser.add_argument('destination', type=Path)
    parser.add_argument('--revision', type=int, default=1)
    parser.add_argument('--report', type=Path)
    args = parser.parse_args()
    report = update(args.source, args.plugin, args.destination, args.revision)
    if args.report:
        args.report.write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
