# Provider playback fixtures

`JustAudioBackend` must be regression-tested with captured provider output as
well as the deterministic WAV fixture. This document is the contract for
adding those samples without committing credentials, user text, or user audio.

## Required samples

For each Provider × format combination, add three independently replayable
samples:

1. `continuous`: normal chunk arrival;
2. `jitter`: a recorded or explicitly derived delayed-chunk sequence that exposes a supply gap;
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

### Capture helper

`tool/capture_provider_fixture.py` captures audio chunks at the HTTP stream
boundary and writes only the raw bytes and their monotonic arrival offsets. It
reads credentials from the environment and deliberately never serializes them,
request/response headers, or source text. It supports the Provider request
shapes used by this repository:

```sh
# Use a dedicated low-privilege test credential. Do not put it in a command,
# fixture, shell profile committed to Git, or chat message.
export OPENAI_API_KEY='...'
python3 tool/capture_provider_fixture.py capture openai

export AZURE_SPEECH_KEY='...'
export AZURE_SPEECH_REGION='eastasia'
python3 tool/capture_provider_fixture.py capture azure

export MIMO_API_KEY='...'
python3 tool/capture_provider_fixture.py capture mimo
```

The first command writes
`assets/fixtures/<provider>/continuous/manifest.json` and numbered binary
chunks. Check that its phrase is redistributable before adding the generated
audio to Git. Then derive a stable network-gap case without relying on an
unreliable local connection:

```sh
python3 tool/capture_provider_fixture.py jitter \
  apps/tts_flow_flutter_example/assets/fixtures/openai/continuous/manifest.json \
  --gap-after 1 --gap-ms 850
```

This creates the neighboring `jitter` fixture with the same audio and a
deterministic 850 ms delay before the selected following chunk. Adjust the
gap and chunk index to target the buffering transition under test. `invalid`
fixtures remain intentionally hand-authored, because their purpose is to test
rejection paths rather than a Provider response.

### Included MiMo samples

`mimo/long_continuous` is an additional live capture from 2026-10-21 using
`mimo-v2.5-tts` and `mimo_default`: 156 provider audio events, 2396160 bytes
of 24 kHz, 16-bit mono PCM, exactly 49.92 seconds. The input is an original,
fixed Chinese test passage about a train journey, with no user content.
The captured arrival offsets span 10.541 seconds; this is stream delivery time,
not audio playback duration. The sample retains real chunks and timing without
repeating, padding, or trimming the generated audio. Its native replay has a
separate long-audio timeout. The raw PCM occupies about 2.29 MiB and is stored
directly in Git, consistent with the short fixtures.
Verified on macOS on 2026-10-21: native playback completes once, with no
waiting or playback failure events. Other platforms remain unverified.

The MiMo PCM fixtures were captured on 2026-10-20 from `mimo-v2.5-tts` with
`mimo_default`, using the fixed phrase `This is a provider fixture.`.
`continuous` contains eight real provider audio events (130560 bytes, 24 kHz,
16-bit mono PCM, 2.72 seconds). Its arrival offsets are relative to the first
audio event. `jitter` preserves those bytes and adds 850 ms after chunk zero;
its gap is deliberately derived, rather than a claim about provider latency.
`invalid` is hand-authored arrival metadata that starts at 1 ms and is rejected
before playback; it does not exercise native decoder failure.

The asset unit test checks loading, matching audio, the derived timing, and
invalid metadata rejection. The captured samples are also included in
`integration_test/just_audio_jitter_test.dart` for explicit native replay.
Verified on macOS on 2026-10-20: continuous playback completes without waiting;
jitter emits waiting, recovers, and completes once; neither emits playback
failure. Other native platforms have not been verified with these samples.
See [Azure setup](azure_speech_setup.md) for the next provider's credentials.

### Offline Azure-format samples

`assets/fixtures/azure_simulated/` contains a locally generated 440 Hz tone,
encoded to match the adapter's `audio-24khz-48kbitrate-mono-mp3` output
specification. These are synthetic audio and timing fixtures, **not captured
Azure responses**, and do not satisfy the live provider capture requirement.
The manifests retain `provenance.type: synthetic` and use the distinct provider
name `azure_simulated` to avoid confusing them with future live captures.

- `continuous`: two chunks, supplied at 0 and 30 ms.
- `jitter`: the same audio, supplied at 0 and 1530 ms; the first chunk contains
  480 ms of audio, so the deliberate delay exposes a supply gap.
- `invalid`: intentionally invalid MP3 bytes, with valid manifest metadata, to
  exercise playback failure rather than manifest rejection.

The tone contains no recorded speech or user audio. The encoded stream is
18288 bytes; continuous and jitter share identical binary content in Git.
To regenerate, install `lameenc==1.8.1` in an isolated Python environment and
run from the repository root:

```sh
python3 tool/generate_azure_simulated_fixture.py --overwrite
```

Ordinary tests only read the committed fixtures; they do not need the encoder,
Azure credentials, an Azure subscription, or network access.
Verified on macOS on 2026-10-21: continuous playback completes without waiting;
jitter emits waiting and recovers to one completion; invalid MP3 emits one
playback failure and no completion. Other platforms remain unverified.

The Azure package's offline HTTP tests cover request construction, voice-list
handling, multi-chunk delivery before response completion, sequence/final
markers, cancellation, authorization failures, throttling/server errors,
timeouts, and format rejection. Real credentials, service acceptance of SSML,
actual Azure MP3 encoder behavior and network timing remain unverified until
the opt-in live contract and real captures can run.
