# tts_flow_flutter

Flutter playback and optional conversion adapters for `tts_flow_dart`.

`JustAudioBackend` is the low-latency playback path: when the provider and
target platform support the negotiated encoded format (for example MP3), bytes
are handed to `just_audio` unchanged. `Decoder` is an explicit whole-payload
conversion output for a non-critical branch that needs PCM; it is not a
streaming decoder and should not sit on the latency-critical playback path.

## Install

```sh
flutter pub add tts_flow_dart tts_flow_flutter
```

Provider engines are separate optional packages, such as `tts_flow_openai`,
`tts_flow_azure`, and `tts_flow_mimo`.

## Quick start

This complete example uses the built-in deterministic engine. Replace it with
an online engine in an application and keep the `SpeakerOutput` wiring.

```dart
import 'package:tts_flow_dart/tts_flow_dart.dart';
import 'package:tts_flow_flutter/tts_flow_flutter.dart';

Future<void> main() async {
  final flow = TtsFlow(
    engine: SineTtsEngine(
      engineId: 'demo-engine',
      supportsStreaming: true,
      chunkCount: 3,
    ),
    defaultOutput: SpeakerOutput(backend: JustAudioBackend()),
  );

  await flow.init();
  flow.preferredFormat = TtsAudioFormat.pcm;
  await flow.speak('Hello from tts_flow').synthesisResult;
  await flow.dispose();
}
```

For a real Flutter application, see
[`apps/tts_flow_flutter_example`](../../apps/tts_flow_flutter_example). It can
run with a bundled fixture, MiMo, or Azure Speech.

## Streaming playback contract

`JustAudioBackend` appends finite `StreamAudioSource` segments to a source
list. Each frozen segment must be suitable as a finite source-list input on
the target platform; this does not require every segment to be a standalone
audio file. Arbitrary network fragments can split frames or omit required
container initialization and are not generally suitable for this path.
It preserves encoded provider audio rather than decoding or packetizing
it in Dart. A provider must therefore keep encoding parameters compatible for
the lifetime of one response; provider-specific discontinuities belong in that
provider adapter or in an application fallback.

The original design was informed by the maintainer's prior MiMo TTS and
edge-tts experience: provider MP3 audio fragments were observed to end at
complete frame boundaries. Preserve those protocol-level audio boundaries
through the adapter instead of treating HTTP reads as audio fragments. Frame
alignment alone does not prove independent decodability; compatible parameters
and native source-list replay still need verification. The committed MiMo MP3
fixture passed macOS replay; edge-tts has no corresponding repository fixture
or platform regression yet. These observations do not establish an AAC/Opus
provider chunking contract. The current `tts_flow_mimo` adapter still exposes
PCM; the MP3 observations and capture do not change its output contract.

Keep the default `bufferEncodedAudio: false` for a verified provider/platform
path with suitable segment boundaries. Full buffering is an explicit fallback
for arbitrary or unknown compressed-byte boundaries when whole-response
latency is acceptable; it is not required just because the format is compressed.
The backend does not automatically detect which contract the input satisfies.

For one compressed file arriving in arbitrary network fragments, opt into
complete-payload playback:

```dart
final output = SpeakerOutput(
  backend: JustAudioBackend(bufferEncodedAudio: true),
);
```

This buffers MP3/AAC/Opus bytes until `finalizePlayback()`, then submits one
finite source with the original bytes. It does not decode or re-encode audio.
It trades first-audio latency for safe frame/container reassembly, and is not
low-latency streaming playback. PCM keeps the normal progressive path.
`maxBufferedEncodedBytes` limits each encoded request to 64 MiB by default;
exceeding the limit stops that session without playing a partial prefix.
Cancellation before finalization discards the buffered bytes.
Full buffering cannot repair corrupt audio, incompatible encoding changes, or
an unsupported platform format. If arbitrary compressed-byte fragmentation
and low first-audio latency are both required, a continuous decoding/output
path is needed; alternatively request PCM when the provider supports it.

Platform errors after audio has reached `just_audio` are exposed through
`JustAudioBackend.playbackErrorStream` and the core request event
`requestPlaybackFailed`. This is distinct from a completed synthesis result.

On Linux and Windows the backend initializes `just_audio_media_kit` before
constructing its player. Calling `JustAudioBackend.ensureInitialized()` in
`main()` is safe but optional.

Read the repository [JustAudioBackend guide](../../docs/just_audio_backend.md)
before shipping: it documents source lifecycle, Android localhost/cleartext
requirements, iOS/macOS ATS, and macOS sandbox network entitlements.

## Tests

```sh
flutter test
```

The repository's native jitter regression lives in the Flutter example and is
run explicitly on a desktop device:

```sh
cd apps/tts_flow_flutter_example
flutter test integration_test/just_audio_jitter_test.dart -d macos
```
