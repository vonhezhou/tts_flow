#!/usr/bin/env python3
import importlib.util
import io
import json
import sys
import tempfile
import unittest
from unittest.mock import patch
from pathlib import Path


_SPEC = importlib.util.spec_from_file_location(
    "capture_provider_fixture", Path(__file__).with_name("capture_provider_fixture.py"),
)
assert _SPEC and _SPEC.loader
capture = importlib.util.module_from_spec(_SPEC)
sys.modules[_SPEC.name] = capture
_SPEC.loader.exec_module(capture)


class CaptureProviderFixtureTest(unittest.TestCase):
    def test_mimo_mp3_capture_requests_mp3_and_preserves_encoded_metadata(self):
        args = capture.parser().parse_args(["capture", "mimo", "--format", "mp3"])
        with patch.object(capture, "_require_env", return_value="fake-key"), patch.object(
            capture, "_post", return_value=io.BytesIO(),
        ) as post:
            metadata, _, is_sse = capture._request_for(args)
        self.assertEqual(json.loads(post.call_args.kwargs["body"])["audio"]["format"], "mp3")
        self.assertEqual(metadata.format, "mp3")
        self.assertEqual(metadata.sample_rate_hz, 24000)
        self.assertIsNone(metadata.bits_per_sample)
        self.assertTrue(is_sse)

    def test_mimo_unsupported_formats_never_send_a_request(self):
        for audio_format in ("aac", "opus"):
            args = capture.parser().parse_args(["capture", "mimo", "--format", audio_format])
            with patch.object(capture, "_require_env", return_value="fake-key"), patch.object(
                capture, "_post",
            ) as post:
                with self.assertRaisesRegex(ValueError, "pcm and mp3 only"):
                    capture._request_for(args)
                post.assert_not_called()

    def test_normalizes_offsets_and_writes_pcm_manifest(self):
        chunks = capture._normalize_offsets(
            [capture.CapturedChunk(b"a", 12), capture.CapturedChunk(b"b", 4)],
        )
        self.assertEqual([chunk.arrival_offset_ms for chunk in chunks], [0, 0])
        metadata = capture.AudioMetadata("mimo", "pcm", 24000, 1, 16, "signedInt")
        with tempfile.TemporaryDirectory() as temp:
            destination = Path(temp) / "mimo" / "continuous"
            capture._write_fixture(destination, metadata, "continuous", chunks, overwrite=False)
            loaded_metadata, loaded_chunks = capture._load_fixture(destination / "manifest.json")
        self.assertEqual(loaded_metadata, metadata)
        self.assertEqual(loaded_chunks, chunks)

    def test_jitter_adds_a_reproducible_gap_after_the_selected_chunk(self):
        source = [
            capture.CapturedChunk(b"a", 0),
            capture.CapturedChunk(b"b", 20),
            capture.CapturedChunk(b"c", 40),
        ]
        derived = capture._derive_jitter(source, gap_after=0, gap_ms=850)
        self.assertEqual([chunk.arrival_offset_ms for chunk in derived], [0, 870, 890])

    def test_mimo_sse_audio_event_decodes_without_retaining_envelope(self):
        event = b'data: {"choices":[{"delta":{"audio":{"data":"AQI="}}}]}'
        self.assertEqual(capture._mimo_event_audio(event), b"\x01\x02")

    def test_mimo_skips_role_finish_and_usage_events(self):
        for event in (
            b'data: {"choices":[{"delta":{"role":"assistant","audio":null}}]}',
            b'data: {"choices":[{"delta":{},"finish_reason":"stop"}]}',
            b'data: {"choices":[],"usage":{"total_tokens":10}}',
            b'data: [DONE]',
        ):
            with self.subTest(event=event):
                self.assertIsNone(capture._mimo_event_audio(event))

    def test_mimo_capture_accepts_a_complete_provider_stream(self):
        stream = io.BytesIO(
            b'data: {"choices":[{"delta":{"audio":null}}]}\r\n\r\n'
            b'data: {"choices":[{"delta":{"audio":{"data":"AQI="}}}]}\n\n'
            b'data: {"choices":[{"delta":{"audio":null},"finish_reason":"stop"}]}\n\n'
            b'data: {"choices":[],"usage":{"total_tokens":10}}\n\n'
            b'data: [DONE]\n\n'
        )
        chunks = capture._capture_mimo_sse(stream)
        self.assertEqual(chunks, [capture.CapturedChunk(b"\x01\x02", 0)])

    def test_mimo_rejects_provider_errors_and_corrupt_audio(self):
        for event in (
            b'data: {"error":{"message":"failed"}}',
            b'data: {"choices":[{"delta":{"audio":{"data":"!invalid"}}}]}',
        ):
            with self.subTest(event=event):
                with self.assertRaisesRegex(RuntimeError, "invalid SSE"):
                    capture._mimo_event_audio(event)

    def test_offsets_are_relative_to_first_audio_not_request_start(self):
        chunks = capture._normalize_offsets([
            capture.CapturedChunk(b"a", 1200),
            capture.CapturedChunk(b"b", 1235),
            capture.CapturedChunk(b"c", 1270),
        ])
        self.assertEqual([chunk.arrival_offset_ms for chunk in chunks], [0, 35, 70])


if __name__ == "__main__":
    unittest.main()
