# tts_flow_dart

tts_flow_dart is a clean, extensible TTS framework for Dart.

Core design choices in this repository:

- Fixed engine wiring: each TtsFlow instance uses one engine. It may have a
  default output, while individual requests may provide their own single or
  composite output.
- Service-scoped defaults: voice/options/format are configured once per service.
- Unified API: `speak(text, utteranceId: ...)` returns a `TtsRequestHandle`.
  Its explicit, single-subscription `chunks` stream is the application-owned
  custom-consumer handoff; `synthesisResult` reports the terminal synthesis
  outcome.
- FIFO queue semantics with halt-on-failure behavior.

For one `TtsFlow`, a `TtsOutput` has exactly one active write. The next
request starts writing only after the previous write finishes or is canceled.
Physical speaker playback may still be observable after a write finishes, but
this does not imply concurrent mixing or concurrent output writes.

By default, synthesis is eager: after A's output write finishes, B can begin
synthesis while A is still physically playing. For a queued playback backend,
limit the amount of synthesized-but-not-yet-terminal audio with:

```dart
const TtsFlowConfig(
  synthesisAdmissionPolicy: TtsBoundedPlaybackBacklogPolicy(
    maxOutstandingPlaybackRequests: 2,
  ),
)
```

This allows A to play while B is synthesized, then waits before C until one of
those playback requests reaches a physical terminal state. The limit applies
only to outputs that retain controllable playback associations; unsynthesized
text remains in the normal FIFO queue. Custom policies receive a snapshot and
can call `flow.refreshSynthesisAdmission()` after their own state changes.

When disposing a flow, active synthesis is first cancelled. The flow waits up
to five seconds for the engine stream to end, then invokes `engine.dispose()`
as the escalation step. It never releases an Output until the active stream has
actually exited. Configure `TtsFlowConfig.activeSynthesisShutdownTimeout` to
use a different pre-escalation grace period, or `null` to wait indefinitely
before asking the engine to dispose.

The shutdown order is fixed: cancel active synthesis, wait for the configured
grace period, dispose the engine, confirm that the active stream has exited,
then dispose managed outputs. An engine must make `SynthesisControl`
cancellation observable promptly and must not complete `dispose()` while its
stream can still write. The timeout is a pre-escalation grace period, not a
request-level network timeout.

## Input limits and request deadlines

`TtsEngine.maxInputCharacterCount` is measured in user-perceived characters
(extended grapheme clusters), not UTF-16 code units or UTF-8 bytes. A value of
`0` means that the engine imposes no framework-level limit. Provider adapters
may still enforce their own documented provider limits.

`TtsOptions` deliberately has no `timeout` field. A synthesis deadline belongs
to the transport that can actually cancel it: configure the adapter's own
`requestTimeout` (`MimoTtsEngine` or `GeminiTtsEngine`) instead. Use `TtsRequestHandle.stopSynthesis()` for explicit
request cancellation.

## Audio Negotiation

Audio negotiation is capability-based and request-scoped.

- Engines expose `outAudioCapabilities`.
- Outputs expose `inAudioCapabilities`.
- `TtsFormatNegotiator` resolves a `TtsAudioSpec` for each request.
- For PCM, negotiation intersects sample rates, bit depth, channels, and
  encoding, then applies deterministic selection rules.

Resolution priority:

1. Service-level preferred format (`TtsFlow.preferredFormat`) if compatible.
2. Service preferred order (`TtsFlowConfig.preferredFormatOrder`).
3. For PCM descriptors, service options sample rate (`TtsOptions.sampleRateHz`)
  when compatible, otherwise a deterministic fallback.

When negotiation fails, `TtsErrorCode.formatNegotiationFailed` now includes
diagnostic context in the message (shared formats/capabilities and preference
inputs) to speed up integration debugging.

## Current Feature Set

- Pluggable engine contract via TtsEngine.
- Pluggable output contract via TtsOutput.
- Built-in outputs:
  - NullOutput (/dev/null-style sink)
  - MemoryOutput
  - Mp3/Wav/AacFileOutput
  - MulticastOutput (fanout to multiple outputs)
  - PrioritizedOutput (low-latency primary output with non-blocking observers)
  - SpeakerOutput (backend abstraction baseline)
- Built-in utilities:
  - TtsFormatNegotiator
  - NonStreamingBridge
- Queue orchestration and controls:
  - init
  - speak
  - pauseQueue / resumeQueue
  - stopActiveSynthesis
  - request-handle playback controls
  - clearQueue
- Voice discovery helpers:
  - getAvailableVoices
  - getDefaultVoice
  - getDefaultVoiceForLocale

## Voice Discovery

Use service-level helper methods to inspect engine voices and locale defaults.
```dart
import 'package:tts_flow_dart/tts_flow_dart.dart';

Future<void> inspectVoices(TtsFlow service) async {
  final voices = await service.getAvailableVoices();
  final defaultVoice = await service.getDefaultVoice();
  final usDefault = await service.getDefaultVoiceForLocale('en-US');

  print('voices: ${voices.map((voice) => voice.voiceId).toList()}');
  print('default: ${defaultVoice.voiceId}');
  print('en-US default: ${usDefault.voiceId}');
}
```

## Quick Start

```dart
import 'package:tts_flow_dart/tts_flow_dart.dart';

Future<void> main() async {
 final service = TtsFlow(
  engine: SineTtsEngine(
   engineId: 'fake-engine',
   supportsStreaming: true,
   chunkCount: 3,
  ),
  defaultOutput: NullOutput(),
 );
 
 await service.init();
 service.preferredFormat = TtsAudioFormat.pcm;
 service.sampleRateHz = 24000;

 final request = service.speak(
   'Hello from flutter uni tts',
   utteranceId: 'hello-1',
 );
 final chunks = await request.chunks.toList();

 print('Received ${chunks.length} chunks.');
 await service.dispose();
}
```

## FileTtsEngine Providers

Use `FileTtsEngine` when you want deterministic playback from pre-existing
audio content instead of synthesizing text dynamically.

### 1) In-memory bytes (`RawBytesContentProvider`)

```dart
import 'dart:typed_data';

import 'package:tts_flow_dart/tts_flow_dart.dart';

Future<void> playFixedBytes() async {
  final payload = Uint8List.fromList([1, 2, 3, 4, 5, 6]);

  final engine = FileTtsEngine(
    engineId: 'fixed-bytes',
    provider: RawBytesContentProvider(
      bytes: payload,
      audioSpec: const TtsAudioSpec.mp3(),
    ),
    chunkSizeBytes: 3,
    maxBytesPerSecond: 8000,
  );

  final chunks = await engine
      .synthesize(
        const TtsRequest(requestKey: 'raw-1', utteranceId: 'raw', text: 'ignored input text'),
        SynthesisControl(),
        const TtsAudioSpec.mp3(),
      )
      .toList();

  print('chunks: ${chunks.length}');
}
```

### 2) MP3 file provider (`Mp3FileContentProvider`)

`Mp3FileContentProvider` strips ID3v2 header bytes and trailing ID3v1 footer
bytes (`TAG`) before streaming audio payload.

```dart
import 'package:tts_flow_dart/tts_flow_dart.dart';

Future<void> playMp3File() async {
  final engine = FileTtsEngine(
    engineId: 'file-mp3',
    provider: Mp3FileContentProvider('assets/prompt.mp3'),
    chunkSizeBytes: 4096,
    maxBytesPerSecond: 32000,
  );

  final stream = engine.synthesize(
    const TtsRequest(requestKey: 'mp3-1', utteranceId: 'mp3', text: 'ignored input text'),
    SynthesisControl(),
    const TtsAudioSpec.mp3(),
  );

  await stream.drain();
}
```

### 3) WAV provider (`WavFileContentProvider`)

Each emitted chunk is wrapped as a self-contained WAV blob
`[44-byte WAV header][chunk PCM bytes]`.

```dart
import 'package:tts_flow_dart/tts_flow_dart.dart';

Future<void> playWavOrPcm() async {
  const wavDescriptor = PcmDescriptor(
    sampleRateHz: 16000,
    bitsPerSample: 16,
    channels: 1,
  );

  final wavEngine = FileTtsEngine(
    engineId: 'file-wav',
    provider: WavFileContentProvider.fromWav('assets/voice.wav'),
    chunkSizeBytes: 2048,
  );

  final pcmEngine = FileTtsEngine(
    engineId: 'file-pcm',
    provider: WavFileContentProvider.fromPcm(
      'assets/raw_16k_mono.pcm',
      const PcmDescriptor(
        sampleRateHz: 16000,
        bitsPerSample: 16,
        channels: 1,
      ),
    ),
    chunkSizeBytes: 2048,
  );

  await wavEngine
      .synthesize(
        const TtsRequest(requestKey: 'wav-1', utteranceId: 'wav', text: 'ignored'),
        SynthesisControl(),
        const TtsAudioSpec.pcm(wavDescriptor),
      )
      .drain();

  await pcmEngine
      .synthesize(
        const TtsRequest(requestKey: 'pcm-1', utteranceId: 'pcm', text: 'ignored'),
        SynthesisControl(),
        const TtsAudioSpec.pcm(wavDescriptor),
      )
      .drain();
}
```

## Example

See the [Dart example guide](../../apps/tts_flow_dart_example/README.md) and
[source](../../apps/tts_flow_dart_example/lib/main.dart). The example subscribes
to each request's chunks immediately, checks `synthesisResult`, and reports the
negotiated format. Its offline smoke test runs as part of workspace Dart tests.
By default it uses `SineTtsEngine`; setting `MIMO_API_KEY` opts into a real
MiMo request. From `apps/tts_flow_dart_example`, run:

```sh
dart run lib/main.dart
```

## MulticastOutput (Multi-output Fanout)

Use `MulticastOutput` when you want one synthesis request to write to multiple
outputs such as null and file at the same time.

```dart
import 'dart:io';

import 'package:tts_flow_dart/tts_flow_dart.dart';

Future<void> main() async {
  final tempDir = await Directory.systemTemp.createTemp('uni_tts_fanout_');

  final output = MulticastOutput(
    outputs: [
      NullOutput(outputId: 'null'),
      WavFileOutput('${tempDir.path}/speech.wav', outputId: 'file'),
    ],
    errorPolicy: MulticastOutputErrorPolicy.bestEffort,
  );

  final service = TtsFlow(
    engine: SineTtsEngine(
      engineId: 'fake-engine',
      supportsStreaming: true,
      chunkCount: 3,
    ),
    defaultOutput: output,
  );

  await service.init();
  service.preferredFormat = TtsAudioFormat.pcm;

  final request = service.speak('hello fanout', utteranceId: 'fanout-1');
  await request.synthesisResult;

  await service.dispose();
}
```

Policy options:

- `MulticastOutputErrorPolicy.bestEffort` (default): failing outputs are
  dropped and remaining outputs continue.
- `MulticastOutputErrorPolicy.failFast`: first output failure aborts the
  request and surfaces a `TtsOutputFailure`.

Tip: use `failFast` when all outputs are required for correctness. Use
`bestEffort` for resilient production fanout where partial output is acceptable.

## PrioritizedOutput (Playback-First Fanout)

Use `PrioritizedOutput` when a latency-critical output, typically a speaker,
must not wait for recording, analytics, or application-owned processing:

```dart
final output = PrioritizedOutput(
  primary: SpeakerOutput(backend: backend),
  auxiliaries: [
    appRecorder,
    playbackMetrics,
  ],
);
```

`primary` is the only child whose lifecycle futures are awaited and whose
capabilities take part in format negotiation. Each auxiliary implements
`TtsAuxiliaryOutput`, whose methods are synchronous notifications. It must
start any asynchronous work itself and own its ordering, buffering, error
handling, and finalization. `PrioritizedOutput` intentionally has no auxiliary
queue or drop policy.

Use `MulticastOutput` instead when every output must receive a complete,
backpressure-coupled stream. For a full external processing pipeline, consume
`TtsRequestHandle.chunks` in the application rather than expanding this
package into a media graph.

For a complete Flutter example with `JustAudioBackend` as the primary and a
bounded, asynchronous file auxiliary that drops remaining work after its first
failure, see
[`auxiliary_output_example.dart`](../../apps/tts_flow_flutter_example/lib/auxiliary_output_example.dart).
It demonstrates the essential ownership rule: an auxiliary queues copied audio
bytes, reports its own asynchronous errors, and never makes player latency or
the request result depend on its file I/O.

## TtsRequestHandle.chunks (Application Processing Handoff)

`TtsRequestHandle.chunks` is the request handle's only single-subscription
audio stream. Attach its one consumer immediately after `speak()` when
transferring a request to an application-owned realtime processing system.

This is intentionally not a broadcast or implicit fanout API. If that system
needs multiple downstream consumers, it owns their buffering, ordering, drop,
retry, and failure policy. Prefer `MulticastOutput` for core-managed,
backpressure-coupled outputs and `PrioritizedOutput` for a primary output with
non-blocking observers.

## TtsRequestHandle.synthesisResult (Output Artifact)

`synthesisResult` completes once synthesis and the primary output's writing
lifecycle reach a terminal state. It always resolves to one of:

- `TtsSynthesisCompletedResult`, containing the `AudioArtifact` returned by
  `TtsOutput.finishWrite()`;
- `TtsSynthesisStoppedResult`, containing why the request ended without an
  artifact;
- `TtsSynthesisFailedResult`, containing the request error.

It does not wait for physical speaker playback. A `PlaybackAudioArtifact`
therefore means that audio was handed to the playback backend, not that the
device has finished playing it. Use request playback events for device-level
completion or failure.

## SpeakerBackend Implementation Checklist

Use this when implementing a custom backend for `SpeakerOutput`.

Lifecycle per request:

1. `init()` prepares backend resources before any playback begins.
2. `startPlayback(requestKey, audioSpec)` creates session state and returns a
   stable `playbackId`.
3. `appendChunk(playbackId, chunks)` appends ordered bytes for that session.
4. End with either:
   - `finalizePlayback(playbackId)` when all synthesized bytes have been
     handed to the backend.
   - `stopPlayback(playbackId, reason)` for cancellation/interruption.
5. If the backend can distinguish real device playback completion, emit
   `playbackCompletedEvents` after the speaker actually finishes.
6. `dispose()` must release resources even if a session is still active.

Semantics:

- `requestSynthesisCompleted` means synthesis/output writing is finished.
- `requestPlaybackCompleted` means the speaker backend reported physical
  playback completion.
- `requestPlaybackFailed` means the physical player failed. It is independent
  from synthesis completion, so it does not turn an already completed
  `speak()` stream into an error or halt the synthesis queue.

Implementation checklist:

- Store per-session state by `playbackId`.
- Preserve write order in `appendChunk`.
- Reject unknown `playbackId` and writes after completion/stop.
- Make `finalizePlayback` idempotent or clearly fail on second call.
- Ensure `stopPlayback` is safe to call after partial writes.
- Return capabilities from `supportedCapabilities` that match the real device.
- Emit `playbackCompletedEvents` only for true physical completion.
- If platform playback can fail asynchronously, implement
  `SpeakerPlaybackFailureAwareBackend` and emit `SpeakerPlaybackFailedEvent`
  with `TtsErrorCode.outputPlaybackFailed`.

Reference skeleton:

```dart
final class MySpeakerBackend implements SpeakerBackend {
  final _sessions = <String, List<int>>{};

  @override
  Stream<SpeakerPlaybackCompletedEvent> get playbackCompletedEvents =>
      const Stream<SpeakerPlaybackCompletedEvent>.empty();

  @override
  Set<AudioCapability> get supportedCapabilities => {const Mp3Capability()};

  @override
  Future<void> init() async {}

  @override
  Future<String> startPlayback({
    required String requestKey,
    required TtsAudioSpec audioSpec,
  }) async {
    final playbackId = 'pb-$requestKey';
    _sessions[playbackId] = <int>[];
    return playbackId;
  }

  @override
  Future<void> appendChunk({
    required String playbackId,
    required TtsChunk chunks,
  }) async {
    if (chunks is! TtsAudioChunk) {
      return;
    }

    final buffer = _sessions[playbackId];
    if (buffer == null) {
      throw StateError('Unknown playbackId: $playbackId');
    }
    buffer.addAll(chunks.bytes);
  }

  @override
  Future<void> finalizePlayback({required String playbackId}) async {
    final buffer = _sessions.remove(playbackId);
    if (buffer == null) {
      throw StateError('Unknown playbackId: $playbackId');
    }
    // Replace with the backend's input-close behavior.
  }

  @override
  Future<void> stopPlayback({required String playbackId, String? reason}) async {
    _sessions.remove(playbackId);
  }

  @override
  Future<void> pausePlayback({required String playbackId}) async {}

  @override
  Future<void> resumePlayback({required String playbackId}) async {}

  @override
  Future<void> dispose() async {
    _sessions.clear();
  }
}
```

For a runnable reference, see `test/speaker_backend_reference_test.dart`.

## Development Commands

```bash
dart pub get
dart analyze
dart test
```

## Milestone Tags

Repository checkpoints are tagged as m1 through m6.
