#!/usr/bin/env python3
"""Capture sanitized TTS provider output as a replayable fixture.

Credentials are deliberately read only from environment variables.  This tool
writes audio bytes plus timing metadata; it never writes request headers,
response headers, credentials, or the source text into a fixture.
"""

from __future__ import annotations

import argparse
import base64
import json
import os
import shutil
import sys
import time
import urllib.error
import urllib.request
from dataclasses import dataclass
from pathlib import Path
from typing import BinaryIO, Iterable
from xml.sax.saxutils import escape as xml_escape


DEFAULT_TEXT = "This is a provider fixture."
DEFAULT_ROOT = Path("apps/tts_flow_flutter_example/assets/fixtures")
CHUNK_SIZE = 4096


@dataclass(frozen=True)
class AudioMetadata:
    provider: str
    format: str
    sample_rate_hz: int
    channels: int
    bits_per_sample: int | None = None
    encoding: str | None = None

    def manifest(self, *, kind: str, chunks: list[dict[str, object]]) -> dict[str, object]:
        result: dict[str, object] = {
            "provider": self.provider,
            "format": self.format,
            "sampleRateHz": self.sample_rate_hz,
            "channels": self.channels,
            "kind": kind,
            "chunks": chunks,
        }
        if self.format == "pcm":
            result["bitsPerSample"] = self.bits_per_sample
            result["encoding"] = self.encoding
        return result


@dataclass(frozen=True)
class CapturedChunk:
    data: bytes
    arrival_offset_ms: int


def _require_env(name: str) -> str:
    value = os.environ.get(name, "").strip()
    if not value:
        raise ValueError(f"{name} must be set in the environment.")
    return value


def _post(url: str, *, headers: dict[str, str], body: bytes) -> BinaryIO:
    request = urllib.request.Request(url, data=body, headers=headers, method="POST")
    try:
        return urllib.request.urlopen(request, timeout=45)  # noqa: S310
    except urllib.error.HTTPError as error:
        detail = error.read(512).decode("utf-8", errors="replace").strip()
        raise RuntimeError(f"Provider returned HTTP {error.code}: {detail}") from error


def _read_available(response: BinaryIO) -> bytes:
    # HTTPResponse.read1 preserves provider delivery boundaries better than
    # response.read(), which tends to fill the requested buffer first.
    reader = getattr(response, "read1", None)
    if reader is None:
        reader = getattr(getattr(response, "fp", None), "read1", None)
    return reader(CHUNK_SIZE) if reader else response.read(CHUNK_SIZE)


def _capture_binary(response: BinaryIO) -> list[CapturedChunk]:
    started = time.monotonic()
    chunks: list[CapturedChunk] = []
    while data := _read_available(response):
        chunks.append(
            CapturedChunk(data=data, arrival_offset_ms=round((time.monotonic() - started) * 1000)),
        )
    if not chunks:
        raise RuntimeError("Provider returned no audio bytes.")
    return _normalize_offsets(chunks)


def _capture_mimo_sse(response: BinaryIO) -> list[CapturedChunk]:
    started = time.monotonic()
    buffered = b""
    chunks: list[CapturedChunk] = []
    while data := _read_available(response):
        buffered = (buffered + data).replace(b"\r\n", b"\n")
        while b"\n\n" in buffered:
            event, buffered = buffered.split(b"\n\n", 1)
            audio = _mimo_event_audio(event)
            if audio:
                chunks.append(
                    CapturedChunk(
                        data=audio,
                        arrival_offset_ms=round((time.monotonic() - started) * 1000),
                    ),
                )
    if buffered.strip():
        audio = _mimo_event_audio(buffered)
        if audio:
            chunks.append(
                CapturedChunk(
                    data=audio,
                    arrival_offset_ms=round((time.monotonic() - started) * 1000),
                ),
            )
    if not chunks:
        raise RuntimeError("MiMo response contained no audio events.")
    return _normalize_offsets(chunks)


def _mimo_event_audio(event: bytes) -> bytes | None:
    lines = [line[5:].strip() for line in event.split(b"\n") if line.startswith(b"data:")]
    if not lines:
        return None
    data = b"\n".join(lines)
    if data == b"[DONE]":
        return None
    try:
        payload = json.loads(data)
        encoded = payload["choices"][0]["delta"]["audio"]["data"]
        return base64.b64decode(encoded, validate=True)
    except (KeyError, IndexError, TypeError, ValueError, json.JSONDecodeError) as error:
        raise RuntimeError("MiMo returned an invalid SSE audio event.") from error


def _normalize_offsets(chunks: Iterable[CapturedChunk]) -> list[CapturedChunk]:
    normalized: list[CapturedChunk] = []
    previous = 0
    for index, chunk in enumerate(chunks):
        offset = 0 if index == 0 else max(previous, chunk.arrival_offset_ms)
        normalized.append(CapturedChunk(data=chunk.data, arrival_offset_ms=offset))
        previous = offset
    return normalized


def _request_for(args: argparse.Namespace) -> tuple[AudioMetadata, BinaryIO, bool]:
    if args.provider == "openai":
        api_key = _require_env("OPENAI_API_KEY")
        audio_format = args.format or "mp3"
        metadata = _metadata("openai", audio_format, args)
        payload = {
            "model": args.model or "gpt-4o-mini-tts",
            "input": args.text,
            "voice": args.voice or "alloy",
            "response_format": audio_format,
        }
        response = _post(
            os.environ.get("OPENAI_TTS_ENDPOINT", "https://api.openai.com/v1/audio/speech"),
            headers={"Authorization": f"Bearer {api_key}", "Content-Type": "application/json"},
            body=json.dumps(payload).encode(),
        )
        return metadata, response, False

    if args.provider == "azure":
        key = _require_env("AZURE_SPEECH_KEY")
        region = _require_env("AZURE_SPEECH_REGION")
        metadata = _metadata("azure", "mp3", args)
        voice = args.voice or "zh-CN-XiaoxiaoNeural"
        ssml = (
            '<speak version="1.0" xml:lang="zh-CN">'
            f'<voice name="{xml_escape(voice)}">{xml_escape(args.text)}</voice></speak>'
        )
        response = _post(
            f"https://{region}.tts.speech.microsoft.com/cognitiveservices/v1",
            headers={
                "Ocp-Apim-Subscription-Key": key,
                "Content-Type": "application/ssml+xml",
                "X-Microsoft-OutputFormat": "audio-24khz-48kbitrate-mono-mp3",
                "User-Agent": "tts-flow-fixture-capture/1.0",
            },
            body=ssml.encode(),
        )
        return metadata, response, False

    api_key = _require_env("MIMO_API_KEY")
    metadata = _metadata("mimo", "pcm", args)
    payload = {
        "model": args.model or "mimo-v2.5-tts",
        "messages": [{"role": "assistant", "content": args.text}],
        "audio": {"format": "pcm16", "voice": args.voice or "mimo_default"},
        "stream": True,
    }
    response = _post(
        os.environ.get("MIMO_TTS_ENDPOINT", "https://api.xiaomimimo.com/v1/chat/completions"),
        headers={"Authorization": f"Bearer {api_key}", "Content-Type": "application/json"},
        body=json.dumps(payload).encode(),
    )
    return metadata, response, True


def _metadata(provider: str, audio_format: str, args: argparse.Namespace) -> AudioMetadata:
    if provider == "mimo":
        return AudioMetadata(provider, "pcm", 24000, 1, 16, "signedInt")
    return AudioMetadata(
        provider,
        audio_format,
        args.sample_rate_hz or 24000,
        args.channels or 1,
        16 if audio_format == "pcm" else None,
        "signedInt" if audio_format == "pcm" else None,
    )


def _write_fixture(destination: Path, metadata: AudioMetadata, kind: str, chunks: list[CapturedChunk], *, overwrite: bool) -> None:
    if destination.exists() and not overwrite:
        raise FileExistsError(f"{destination} already exists; pass --overwrite to replace it.")
    if destination.exists():
        shutil.rmtree(destination)
    destination.mkdir(parents=True)
    manifest_chunks: list[dict[str, object]] = []
    for index, chunk in enumerate(chunks):
        filename = f"{index:03}.bin"
        (destination / filename).write_bytes(chunk.data)
        manifest_chunks.append({"file": filename, "arrivalOffsetMs": chunk.arrival_offset_ms})
    (destination / "manifest.json").write_text(
        json.dumps(metadata.manifest(kind=kind, chunks=manifest_chunks), indent=2) + "\n",
        encoding="utf-8",
    )


def _derive_jitter(chunks: list[CapturedChunk], *, gap_after: int, gap_ms: int) -> list[CapturedChunk]:
    if not 0 <= gap_after < len(chunks):
        raise ValueError(f"--gap-after must name a chunk from 0 to {len(chunks) - 1}.")
    if gap_ms <= 0:
        raise ValueError("--gap-ms must be positive.")
    return [
        CapturedChunk(
            data=chunk.data,
            arrival_offset_ms=chunk.arrival_offset_ms + (gap_ms if index > gap_after else 0),
        )
        for index, chunk in enumerate(chunks)
    ]


def _load_fixture(manifest_path: Path) -> tuple[AudioMetadata, list[CapturedChunk]]:
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    metadata = AudioMetadata(
        manifest["provider"], manifest["format"], manifest["sampleRateHz"], manifest["channels"],
        manifest.get("bitsPerSample"), manifest.get("encoding"),
    )
    parent = manifest_path.parent
    chunks = [
        CapturedChunk((parent / item["file"]).read_bytes(), item["arrivalOffsetMs"])
        for item in manifest["chunks"]
    ]
    return metadata, chunks


def capture(args: argparse.Namespace) -> None:
    metadata, response, is_sse = _request_for(args)
    with response:
        chunks = _capture_mimo_sse(response) if is_sse else _capture_binary(response)
    destination = args.root / metadata.provider / "continuous"
    _write_fixture(destination, metadata, "continuous", chunks, overwrite=args.overwrite)
    print(f"Wrote {len(chunks)} chunks ({sum(len(chunk.data) for chunk in chunks)} bytes) to {destination}")


def jitter(args: argparse.Namespace) -> None:
    metadata, chunks = _load_fixture(args.manifest)
    derived = _derive_jitter(chunks, gap_after=args.gap_after, gap_ms=args.gap_ms)
    destination = args.destination or args.manifest.parent.parent / "jitter"
    _write_fixture(destination, metadata, "jitter", derived, overwrite=args.overwrite)
    print(f"Wrote deterministic {args.gap_ms}ms gap fixture to {destination}")


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser(description=__doc__)
    commands = result.add_subparsers(dest="command", required=True)
    capture_parser = commands.add_parser("capture", help="Capture a sanitized continuous provider fixture.")
    capture_parser.add_argument("provider", choices=("openai", "azure", "mimo"))
    capture_parser.add_argument("--root", type=Path, default=DEFAULT_ROOT)
    capture_parser.add_argument("--text", default=DEFAULT_TEXT, help="Use only a redistributable, non-user phrase.")
    capture_parser.add_argument("--voice")
    capture_parser.add_argument("--model")
    capture_parser.add_argument("--format", choices=("pcm", "mp3", "opus", "aac"))
    capture_parser.add_argument("--sample-rate-hz", type=int)
    capture_parser.add_argument("--channels", type=int)
    capture_parser.add_argument("--overwrite", action="store_true")
    capture_parser.set_defaults(func=capture)
    jitter_parser = commands.add_parser("jitter", help="Derive a deterministic supply gap from a continuous fixture.")
    jitter_parser.add_argument("manifest", type=Path)
    jitter_parser.add_argument("--destination", type=Path)
    jitter_parser.add_argument("--gap-after", type=int, default=0)
    jitter_parser.add_argument("--gap-ms", type=int, default=850)
    jitter_parser.add_argument("--overwrite", action="store_true")
    jitter_parser.set_defaults(func=jitter)
    return result


def main() -> int:
    args = parser().parse_args()
    try:
        args.func(args)
    except (FileExistsError, ValueError, RuntimeError, OSError) as error:
        print(f"fixture capture failed: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
