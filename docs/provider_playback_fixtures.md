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

### Gemini integration status

`tts_flow_gemini` uses `googleai_dart` to decode Gemini 3.1 Flash TTS streams.
The native regression includes a simulated Gemini SSE response containing the
existing MiMo PCM fixture, verifying SDK → adapter → TtsFlow → JustAudio
playback offline. This mock transport case remains distinct from the real
Gemini provider capture described below.
The SDK mock transport playback was verified on macOS on 2026-10-21:
one completion, no waiting, and no playback failure. Other native platforms
have not been verified for this adapter path.

### Captured Gemini samples

On 2026-10-21, the [live contract tool](../packages/tts_flow_gemini/tool/live_contract_check.dart)
successfully called `gemini-3.1-flash-tts-preview` with voice `Kore` and the
fixed phrase `This is a provider fixture.` through the actual SDK and TtsFlow.
It verified both the PCM stream and the WAV output header and length.
`assets/fixtures/gemini/continuous/` contains 63 chunks totaling 120960 bytes
(24 kHz, 16-bit mono PCM, 2.52 seconds). Arrival offsets measure adapter output
relative to the first emitted audio chunk, not raw HTTP boundaries. The
recorded offsets are retained, including early 196 ms and 235 ms supply gaps.
Whether these short gaps produce waiting depends on native-player startup:
local runs observed both zero and two waiting events, each completing once
without playback failure. Consequently the normal capture test verifies
completion and attribution/recovery of any waiting events, without prescribing
their count. The derived jitter case requires a waiting event.

`jitter` has identical audio with an additional derived 850 ms gap after chunk
zero. Its provenance explicitly marks it as derived. `invalid` is hand-authored
metadata starting at 1 ms, rejected before playback; it does not test corrupt
PCM decoding. No credentials, request headers, or account metadata are stored.
Verified on macOS on 2026-10-21: both audio fixtures complete exactly once
without playback failure, derived jitter emits waiting and recovers, and the
invalid fixture is rejected before playback. Other platforms remain unverified.
See the [adapter guide](../packages/tts_flow_gemini/README.md) to recapture.

On 2026-10-22, a separate fixed, non-user test passage produced
`gemini/long_continuous/`: 1210 real audio chunks, 2323200 bytes of PCM24K
(48.40 seconds, approximately 2.22 MiB of audio). The passage is defined in
`packages/tts_flow_gemini/tool/live_contract_check.dart`; regenerate with
`--capture-fixture --long`. The captured audio was not trimmed, padded, or
repeated. Original adapter-output offsets are preserved. This is a separate
sample; the short fixtures remain unchanged. The offline asset test checks
the 30–60 second range and PCM sample integrity, and the native regression
replays the recorded timing and checks one completion with no playback failure.
The long sample passed native macOS replay on 2026-10-22; other platforms have
not been verified for this sample.

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

### Compressed speech coverage (2026-10-22)

The committed fixtures now cover PCM, MP3, AAC (ADTS), and Opus (Ogg).
AAC/Opus are explicitly **locally transcoded derivatives**, not native provider
responses. They exercise the playback format paths without a new subscription.

| Source / request | Result |
| --- | --- |
| MiMo `mimo-v2.5-tts`, streaming `audio.format=mp3` | Success; 7 original SSE audio chunks, 23400 bytes |
| MiMo `audio.format=aac`, streaming and non-streaming | HTTP 400, `Param Incorrect` |
| Gemini Interactions `gemini-3.1-flash-tts-preview`, `audio/mp3`, streaming and non-streaming | HTTP 400, `Audio MIME type AUDIO_MP3 is not supported` |
| Same Gemini model, streaming `audio/ogg_opus` | HTTP 400, `Audio MIME type AUDIO_OGG_OPUS is not supported` |
| Gemini Interactions `gemini-3.8-flash-tts`, streaming Ogg Opus | HTTP 400, `Audio MIME type AUDIO_OGG_OPUS is not supported` |

Gemini probes used API revision `2026-05-20`. These results describe the tested
model/API combinations; a generic API format enum does not guarantee that a
particular model accepts it. [Google Cloud Text-to-Speech Gemini TTS](https://docs.cloud.google.com/text-to-speech/docs/gemini-tts)
is a separate product and was not enabled or tested here.

The [MiMo API reference](https://mimo.mi.com/static/docs/api/audio/tts.md)
lists `wav`, `mp3`, `pcm`, and `pcm16`; it does not advertise AAC or Opus.
Its [speech synthesis guide](https://mimo.mi.com/static/docs/quick-start/usage-guide/audio/speech-synthesis-v2.5.md)
recommends PCM16 for streaming. The production MiMo adapter therefore keeps
its PCM contract; only the capture helper gains an explicit MP3 option:

```sh
# Reads MIMO_API_KEY from the environment; uses a fixed test phrase.
python3 tool/capture_provider_fixture.py capture mimo --format mp3
```

This writes `mimo_mp3/continuous`, preserving the existing PCM capture.
`mimo_mp3/jitter` retains identical bytes and adds 1500 ms after chunk zero;
`invalid` contains deliberately corrupt bytes with valid manifest metadata.
The original MP3 fragments contain independent encoder metadata. FFmpeg 7.1
successfully decoded all 123 frames at 24 kHz mono, but reported
`invalid concatenated file detected - using bitrate for duration` when reading
the concatenation. This sample does not reproduce the previously observed
sample-rate/channel changes, nor prove that other MiMo MP3 responses avoid them.
Original bytes are retained without repairing or re-encoding the capture.

`derived_aac` and `derived_opus` encode the existing 2.72-second MiMo PCM
fixture with FFmpeg 7.1: AAC at 24 kHz mono / 48 kbps in ADTS, and Opus at
48 kHz mono / 48 kbps in Ogg. Manifests retain source SHA-256, container,
encoder, and explicit provenance. Regenerate from the repository root:

```sh
python3 tool/generate_encoded_playback_fixtures.py --ffmpeg /path/to/ffmpeg --overwrite
```

FFmpeg is needed only for regeneration, with `aac` and `libopus` encoders;
ordinary playback tests need neither FFmpeg nor credentials. No runtime codec
dependency was added. The new binary samples total approximately 112 KiB and
are stored directly in Git.

Each derivative has a whole-file `continuous`, a two-file `jitter` supplied
at 0 and 2500 ms, and corrupt `invalid` audio. Jitter segments are independently
encoded and self-contained (including OpusHead/Tags for each Ogg file). This
covers delayed playlist supply, **not arbitrary network fragmentation of one
Ogg bitstream**. Provider-native AAC/Opus streaming acceptance remains untested.

All nine compressed cases passed native macOS replay on 2026-10-22: valid
samples complete once with no playback failure; deliberate supply gaps emit
attributed waiting and recover; corrupt samples emit one failure and no
completion. Other platforms remain unverified. Ogg Opus required correcting
`TtsAudioFormat.opus.mimeType` from `audio/opus` to the container MIME
`audio/ogg`; with the old MIME, macOS rejected the valid fixture with
`-11828 Cannot Open`. Playback event assertions do not measure recorded speaker
output and do not certify the absence of audible clipping or glitches.


### Arbitrary network fragmentation of one encoded stream

These cases deliberately split a single file at arbitrary byte offsets. They
do not model the maintainer's prior MiMo TTS and edge-tts MP3 observations,
where provider audio fragments were aligned to complete MP3 frames. That
experience motivated the default finite-source playback design. It is not a
universal provider guarantee: edge-tts has no corresponding repository fixture
or platform regression, and native AAC/Opus provider chunk boundaries remain
unverified. See the [backend boundary and mode-selection guide](just_audio_backend.md)
for the distinction between transport reads, provider audio fragments, and
finite playback sources. Frame alignment still requires platform validation;
it alone does not prove that every fragment is independently decodable.

`ProviderPlaybackFixture.fragmented()` reuses each existing `derived_aac` or
`derived_opus` continuous file without re-encoding it or adding container
headers. At test time it cuts at byte offsets 1, 2, 5, 13, 26, 27, 28, and 31,
then at multiples of 389. This splits ADTS sync/header/payload bytes and Ogg
header/lacing/packet data; chunks are not independent audio files. A second
schedule adds 2500 ms to chunks starting in the latter half of the same file.
The asset regression checks byte-for-byte reconstruction and timing. No new
binary fixtures or speech sources are added for these cases.

The native regression revealed that the default finite-segment playback path
cannot accept these arbitrary boundaries: freezing an incomplete segment can
cause native decode errors. The new explicit `JustAudioBackend(bufferEncodedAudio:
true)` mode accumulates the original encoded bytes until finalization and
submits one complete source, with a default 64 MiB per-request bound. It does
not transcode or introduce a codec dependency; PCM remains progressive.
This is whole-payload playback, **not a low-latency incremental decoder**.
An input delay becomes a first-playback delay rather than an underflow event.
This fallback does not replace the default progressive path for verified
provider segments, and its success does not establish support for arbitrary
compressed-byte fragmentation with low-latency playback.

Verified on macOS on 2026-10-22: four cases (AAC/Opus × regular/delayed supply)
complete once, without playback failure or waiting; each reports 2600–3000 ms
of audio, rejecting success after only an early frame/page. Two additional
corrupt-payload cases fail once without completion. Existing nine compressed
independent-segment cases still pass. Other platforms remain unverified, and
none of these event tests certify recorded speaker waveform quality.
