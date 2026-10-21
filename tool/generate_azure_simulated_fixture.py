#!/usr/bin/env python3
"""Generate offline MP3 fixtures matching Azure's output specification.

Requires lameenc==1.8.1 only when regenerating. No provider is contacted.
Audio is a locally generated 440 Hz tone; all arrival times are simulated.
"""

import argparse
import json
import math
import struct
from pathlib import Path

import lameenc

from capture_provider_fixture import AudioMetadata, CapturedChunk, _write_fixture


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--overwrite", action="store_true")
    args = parser.parse_args()
    root = Path("apps/tts_flow_flutter_example/assets/fixtures/azure_simulated")
    if root.exists() and not args.overwrite:
        parser.error(f"{root} already exists; pass --overwrite to regenerate")
    pcm = b"".join(
        struct.pack("<h", round(3000 * math.sin(2 * math.pi * 440 * i / 24000)))
        for i in range(3 * 24000)
    )
    encoder = lameenc.Encoder()
    encoder.set_bit_rate(48)
    encoder.set_in_sample_rate(24000)
    encoder.set_channels(1)
    encoder.set_quality(2)
    audio = bytes(encoder.encode(pcm) + encoder.flush())
    # MPEG-2 Layer III, 48 kbps / 24 kHz: 144 bytes and 24 ms per frame.
    # Keep twenty whole frames in the first chunk (480 ms of audio).
    split = 20 * 144
    metadata = AudioMetadata("azure_simulated", "mp3", 24000, 1)
    for kind, chunks in {
        "continuous": [CapturedChunk(audio[:split], 0), CapturedChunk(audio[split:], 30)],
        "jitter": [CapturedChunk(audio[:split], 0), CapturedChunk(audio[split:], 1530)],
        "invalid": [CapturedChunk(b"Deliberately invalid MP3 bytes.", 0)],
    }.items():
        destination = root / kind
        _write_fixture(destination, metadata, kind, chunks, overwrite=args.overwrite)
        manifest_path = destination / "manifest.json"
        manifest = json.loads(manifest_path.read_text())
        manifest["provenance"] = {
            "type": "synthetic",
            "generator": "tool/generate_azure_simulated_fixture.py",
            "encoder": "lameenc==1.8.1",
            "timing": "simulated",
            "bitrateKbps": 48,
        }
        manifest_path.write_text(json.dumps(manifest, indent=2) + "\n")
    print(f"Wrote synthetic MP3 fixtures ({len(audio)} audio bytes); no Azure request made.")


if __name__ == "__main__":
    main()
