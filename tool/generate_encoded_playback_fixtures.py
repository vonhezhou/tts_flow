#!/usr/bin/env python3
"""Use FFmpeg to derive explicit AAC/Opus playback fixtures from captured PCM.

Only regeneration needs FFmpeg (tested with 7.1); ordinary tests use assets.
These are locally transcoded speech, never native provider AAC/Opus output.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import subprocess
import tempfile
from pathlib import Path

from capture_provider_fixture import AudioMetadata, CapturedChunk, _write_fixture


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--ffmpeg", default="ffmpeg")
    parser.add_argument("--overwrite", action="store_true")
    args = parser.parse_args()
    root = Path("apps/tts_flow_flutter_example/assets/fixtures")
    source_path = root / "mimo/continuous/manifest.json"
    source = json.loads(source_path.read_text())
    pcm = b"".join((source_path.parent / c["file"]).read_bytes() for c in source["chunks"])
    for fmt in ("aac", "opus"):
        if (root / f"derived_{fmt}").exists() and not args.overwrite:
            parser.error(f"derived_{fmt} exists; pass --overwrite to regenerate")
    with tempfile.TemporaryDirectory() as temp:
        for fmt, rate, encoder, container in (
            ("aac", 24000, "aac", "adts"),
            ("opus", 48000, "libopus", "ogg"),
        ):
            def encode(data: bytes, label: str) -> bytes:
                output = Path(temp) / f"{fmt}-{label}.bin"
                subprocess.run([
                    args.ffmpeg, "-hide_banner", "-loglevel", "error", "-y",
                    "-f", "s16le", "-ar", "24000", "-ac", "1", "-i", "pipe:0",
                    "-map_metadata", "-1", "-c:a", encoder, "-b:a", "48000",
                    "-ar", str(rate), "-ac", "1", "-f", container, str(output),
                ], input=data, check=True)
                return output.read_bytes()

            whole = encode(pcm, "whole")
            # 抖动用独立可解码的两段；Ogg 第二段保留自己的 OpusHead/Tags。
            # 这是播放列表供给测试，不冒充原生服务或单个 Ogg 流的网络分块。
            first, second = encode(pcm[:48000], "first"), encode(pcm[48000:], "second")
            metadata = AudioMetadata(f"derived_{fmt}", fmt, rate, 1)
            for kind, chunks in {
                "continuous": [CapturedChunk(whole, 0)],
                "jitter": [CapturedChunk(first, 0), CapturedChunk(second, 2500)],
                "invalid": [CapturedChunk(b"Deliberately invalid encoded audio.", 0)],
            }.items():
                destination = root / f"derived_{fmt}" / kind
                _write_fixture(destination, metadata, kind, chunks, overwrite=args.overwrite)
                manifest_path = destination / "manifest.json"
                manifest = json.loads(manifest_path.read_text())
                manifest["provenance"] = {
                    "type": "transcoded" if kind != "invalid" else "hand-authored",
                    "source": "../../mimo/continuous/manifest.json",
                    "sourcePcmSha256": hashlib.sha256(pcm).hexdigest(),
                    "generator": "tool/generate_encoded_playback_fixtures.py",
                    "encoder": encoder, "container": container,
                    "timing": "simulated playlist supply; independently encoded segments",
                }
                manifest_path.write_text(json.dumps(manifest, indent=2) + "\n")
            print(f"Wrote derived_{fmt}: {len(whole)} bytes of whole-file audio.")


if __name__ == "__main__":
    main()
