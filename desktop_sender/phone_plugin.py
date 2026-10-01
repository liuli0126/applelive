"""Export the signed injector library without modifying its Mach-O bytes."""
from __future__ import annotations

import ipaddress
from pathlib import Path
import sys


def plugin_directory() -> Path:
    if getattr(sys, "frozen", False):
        return Path(sys.executable).parent
    return Path(__file__).resolve().parent.parent / "obs-plugin"


def plugin_path(directory: Path) -> Path:
    return directory / "phone-plugin" / "AppleLive.dylib"


def download_name(host: str, port: int) -> str:
    address = ipaddress.IPv4Address(host)
    if address.is_loopback or address.is_multicast or int(address) >> 24 in (0, 255):
        raise ValueError("A computer LAN IPv4 address is required")
    if not 1 <= port <= 65535:
        raise ValueError("Invalid sender port")
    return f"AppleLive-{address}-{port}.dylib"


def download_url(host: str, port: int) -> str:
    download_name(host, port)
    return f"http://{host}:{port}/phone-plugin"
