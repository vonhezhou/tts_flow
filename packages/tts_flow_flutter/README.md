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
list. Each frozen segment must be independently decodable; arbitrary network
fragments of a single AAC/Opus file do not satisfy that requirement.
It preserves encoded provider audio rather than decoding or packetizing
it in Dart. A provider must therefore keep encoding parameters compatible for
the lifetime of one response; provider-specific discontinuities belong in that
provider adapter or in an application fallback.

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
