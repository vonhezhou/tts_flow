# Provider playback fixtures

`JustAudioBackend` must be regression-tested with captured provider output as
well as the deterministic WAV fixture. This document is the contract for
adding those samples without committing credentials, user text, or user audio.

## Required samples

For each Provider × format combination, add three independently replayable
samples:

1. `continuous`: normal chunk arrival;
2. `jitter`: a real delayed-chunk sequence that exposes a supply gap;
3. `invalid`: an intentionally malformed or unsupported response.

Store binary audio only when it is generated from a short, non-user test
phrase and can be legally redistributed. Never include a source API response
that contains credentials, request headers, account identifiers, or user text.

Each sample has a neighboring JSON manifest with this shape:

```json
{
  "provider": "azure",
  "format": "mp3",
  "sampleRateHz": 24000,
  "channels": 1,
  "kind": "continuous",
  "chunks": [
    {"file": "000.bin", "arrivalOffsetMs": 0},
    {"file": "001.bin", "arrivalOffsetMs": 35}
  ]
}
```

`format` accepts `pcm`, `mp3`, `opus`, and `aac`. `sampleRateHz` and
`channels` are required positive capture metadata for every format. For `pcm`, add
`bitsPerSample` and `encoding` (`signedInt`, `unsignedInt`, or `float`) so the
fixture can reconstruct its exact `TtsAudioSpec`. The first chunk must have an
`arrivalOffsetMs` of `0`; subsequent offsets are elapsed from the beginning of
the capture and must be non-decreasing.

Put fixtures under
`apps/tts_flow_flutter_example/assets/fixtures/<provider>/<kind>/`. The
`ProviderPlaybackFixture` loader replays their raw chunks directly through a
deterministic engine, without credentials or network access. A fixture's
manifest is the only timing source: do not add artificial delays in its test.

The test fixture loader must replay chunks in manifest order and apply only the
recorded arrival offsets. It must assert playback completion, waiting events,
and playback failures; it must not require live credentials or network access.

## Collection procedure

1. Run the appropriate live-contract workflow or local script with a dedicated
   test credential and a fixed, non-user phrase.
2. Strip all metadata except the audio bytes, format, and arrival timing.
3. Replay the captured stream on at least one real target device before adding
   it to the fixture set.
4. Record platforms that have been verified in the manifest or test name; do
   not infer support on untested platforms.
