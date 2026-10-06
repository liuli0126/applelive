"""Inspect the actual rootless package, paired plugin and signed Mach-O slices."""

import hashlib
import io
import plistlib
import struct
import sys
import tarfile
from pathlib import Path


def ar_members(data):
    assert data[:8] == b'!<arch>\n', 'Expected Debian ar archive'
    cursor = 8
    result = {}
    while cursor < len(data):
        header = data[cursor:cursor + 60]
        assert len(header) == 60 and header[-2:] == b'`\n'
        name = header[:16].decode('ascii').strip().rstrip('/')
        size = int(header[48:58])
        cursor += 60
        assert name not in result and cursor + size <= len(data)
        result[name] = data[cursor:cursor + size]
        cursor += size + size % 2
    assert cursor == len(data)
    return result


def tar_members(data):
    result = {}
    with tarfile.open(fileobj=io.BytesIO(data), mode='r:*') as archive:
        for member in archive.getmembers():
            name = member.name.removeprefix('./').rstrip('/')
            if not name or name == '.':
                continue
            assert not name.startswith('/') and '..' not in name.split('/')
            assert name not in result and member.uid == member.gid == 0
            assert member.isdir() or member.isfile(), 'Unexpected package link'
            result[name] = (member, archive.extractfile(member).read() if member.isfile() else None)
    return result


def verify_executable(data, expected_entitlements):
    magic, count = struct.unpack_from('>II', data)
    assert magic == 0xCAFEBABE and count == 2
    subtypes = set()
    for index in range(count):
        cpu, subtype, offset, size, _ = struct.unpack_from('>IIIII', data, 8 + index * 20)
        assert cpu == 0x0100000C and offset + size <= len(data)
        subtypes.add(subtype)
        binary = data[offset:offset + size]
        header = struct.unpack_from('<IIIIIIII', binary)
        assert header[:4] == (0xFEEDFACF, cpu, subtype, 2), 'Expected device executable'
        cursor = 32
        signature = None
        minimum = None
        for _ in range(header[4]):
            command, length = struct.unpack_from('<II', binary, cursor)
            assert length >= 8 and cursor + length <= 32 + header[5]
            if command == 0x25:
                minimum = struct.unpack_from('<I', binary, cursor + 8)[0]
            elif command == 0x32:
                platform, minimum = struct.unpack_from('<II', binary, cursor + 8)
                assert platform == 2
            elif command in (0xC, 0x80000018, 0x8000001F):
                name_offset = struct.unpack_from('<I', binary, cursor + 8)[0]
                dependency = binary[cursor + name_offset:cursor + length].split(b'\0', 1)[0].decode()
                assert dependency.startswith(('/System/Library/', '/usr/lib/')), dependency
            elif command == 0x1D:
                start, size = struct.unpack_from('<II', binary, cursor + 8)
                assert start + size <= len(binary)
                signature = binary[start:start + size]
            cursor += length
        assert cursor == 32 + header[5] and minimum == 0x000F0000 and signature
        magic, size, blobs = struct.unpack_from('>III', signature)
        assert magic == 0xFADE0CC0 and size <= len(signature)
        entitlements = None
        for i in range(blobs):
            slot, start = struct.unpack_from('>II', signature, 12 + 8 * i)
            blob_magic, length = struct.unpack_from('>II', signature, start)
            assert start + length <= size
            if slot == 5:
                assert blob_magic == 0xFADE7171
                entitlements = plistlib.loads(signature[start + 8:start + length])
        assert entitlements == expected_entitlements, 'Embedded entitlements differ'
    assert subtypes == {0, 0x80000002}, 'Expected arm64 and modern arm64e'


def verify(package, plugin):
    root = Path(__file__).resolve().parents[1]
    members = ar_members(package.read_bytes())
    assert members['debian-binary'] == b'2.0\n'
    control = tar_members(next(value for name, value in members.items() if name.startswith('control.tar')))
    payload = tar_members(next(value for name, value in members.items() if name.startswith('data.tar')))
    meta = dict(line.split(': ', 1) for line in control['control'][1].decode().splitlines() if ': ' in line)
    assert meta['Package'] == 'com.applelive.uvchost' and meta['Architecture'] == 'iphoneos-arm64'
    assert meta['Depends'] == 'firmware (>= 15.0)'
    for name in ('postinst', 'prerm', 'postrm'):
        member, data = control[name]
        assert member.mode == 0o755 and data.startswith(b'#!/bin/sh\n')
        assert b'\r' not in data
    for name, (member, data) in payload.items():
        assert name == 'var' or name == 'var/jb' or name.startswith('var/jb/')
        assert member.mode == (0o755 if member.isdir() or name.endswith(('/AppleLiveUVCHost', '/AppleLiveUSB')) else 0o644), name
    for name, entitlements in (
        ('var/jb/usr/libexec/AppleLiveUVCHost', 'USBHost.entitlements'),
        ('var/jb/Applications/AppleLiveUSB.app/AppleLiveUSB', 'Setup.entitlements'),
    ):
        verify_executable(payload[name][1], plistlib.loads((root / 'ios-uvc-service' / entitlements).read_bytes()))
        print('Verified device architectures, iOS 15 minimum, imports and declared entitlements:', name)
    embedded = payload['var/jb/Library/AppleLive/AppleLive.dylib'][1]
    assert embedded == plugin.read_bytes(), 'Installer and standalone plugin differ'
    launch = plistlib.loads(payload['var/jb/Library/LaunchDaemons/com.applelive.uvchost.plist'][1])
    assert launch['UserName'] == 'mobile' and launch['Label'] == 'com.applelive.uvchost'
    assert launch['ProgramArguments'] == ['/var/jb/usr/libexec/AppleLiveUVCHost']
    info = plistlib.loads(payload['var/jb/Applications/AppleLiveUSB.app/Info.plist'][1])
    assert info['CFBundleExecutable'] == 'AppleLiveUSB' and info['MinimumOSVersion'] == '15.0'
    assert info['CFBundleShortVersionString'] == meta['Version'], 'Service/app version mismatch'
    for license in ('libusb-LICENSE.txt', 'libuvc-LICENSE.txt', 'USBHost-NOTICE.txt', 'SOURCE.txt'):
        assert payload['var/jb/usr/share/doc/com.applelive.uvchost/' + license][1]
    print('Verified rootless layout, ownership, permissions, service registration and matched plugin')
    print('Installer SHA256:', hashlib.sha256(package.read_bytes()).hexdigest())


if __name__ == '__main__':
    verify(Path(sys.argv[1]), Path(sys.argv[2]))
