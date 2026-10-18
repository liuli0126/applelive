"""Measure actual DirectShow-to-USB PCM packet cadence without saving audio.
Run explicitly on Windows with a working capture endpoint; not a hardware-free CI test.
"""
import argparse
from argparse import Namespace
import json
from pathlib import Path
import statistics
import subprocess
import threading
import time

from sender import AUDIO_HEADER, audio_command, capture_audio


def measure(ffmpeg, device, seconds):
    args = Namespace(ffmpeg=str(ffmpeg), input_url=None, audio_device=device,
                     channels=2, sample_rate=48000)
    command = audio_command(args)
    command[-1:-1] = ['-t', str(seconds)]
    arrivals = []
    errors = []

    def publish(packet):
        kind, rate, channels = AUDIO_HEADER.unpack_from(packet)
        assert (kind, rate, channels) == (b'audi', 48000, 2)
        assert (len(packet) - AUDIO_HEADER.size) % (channels * 4) == 0
        frames = (len(packet) - AUDIO_HEADER.size) // (channels * 4)
        arrivals.append((time.monotonic(), frames))

    process = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                               creationflags=getattr(subprocess, 'CREATE_NO_WINDOW', 0))
    watchdog = threading.Timer(seconds + 12, lambda: process.kill() if process.poll() is None else None)
    watchdog.start()
    try:
        capture_audio(process, Namespace(publish=publish), 48000, 2)
        code = process.wait(timeout=3)
        if code:
            raise RuntimeError(process.stderr.read().decode(errors='replace')[-1500:])
    finally:
        watchdog.cancel()
        if process.poll() is None:
            process.kill()
            process.wait()
    gaps = [(b[0] - a[0]) * 1000 for a, b in zip(arrivals, arrivals[1:])]
    frames = sum(item[1] for item in arrivals)
    summary = {'packets': len(arrivals), 'frames': frames,
               'audio_seconds': round(frames / 48000, 3),
               'max_gap_ms': round(max(gaps, default=0), 2),
               'p95_gap_ms': round(sorted(gaps)[int(len(gaps) * .95)], 2) if gaps else 0,
               'gaps_over_200ms': sum(g > 200 for g in gaps)}
    assert len(arrivals) > seconds * 20, summary
    assert seconds * 48000 * .95 <= frames <= (seconds + .2) * 48000, summary
    assert summary['gaps_over_200ms'] == 0, summary
    return summary


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--ffmpeg', required=True, type=Path)
    parser.add_argument('--device', required=True)
    parser.add_argument('--seconds', type=int, default=8)
    args = parser.parse_args()
    if not 3 <= args.seconds <= 30:
        parser.error('--seconds must be between 3 and 30')
    print(json.dumps(measure(args.ffmpeg, args.device, args.seconds)), flush=True)
