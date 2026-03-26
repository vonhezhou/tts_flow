# tts_flow_dart

tts_flow_dart is a clean, extensible TTS framework for Dart.

Core design choices in this repository:

- Fixed service wiring: each TtsFlow instance uses one engine and one output.
- Service-scoped defaults: voice/options/format are configured once per service.
- Unified API: speak(requestId, text, [params]) always returns a stream of `TtsChunk`.
- FIFO queue semantics with halt-on-failure behavior.

## Audio Negotiation

Audio negotiation is capability-based and request-scoped.

- Engines expose `supportedCapabilities`.
- Outputs expose `acceptedCapabilities`.
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
  - SpeakerOutput (backend abstraction baseline)
- Built-in adapters/utilities:
  - TtsFormatNegotiator
  - NonStreamingBridge
  - OpenAiTtsEngine transport adapter API
- Queue orchestration and controls:
  - init
  - speak
  - pauseCurrent
  - resumeCurrent
  - stopCurrent
  - clearQueue
- Voice discovery helpers:
  - getAvailableVoices
  - getDefaultVoice
  - getDefaultVoiceForLocale

## Voice Discovery

Use service-level helper methods to inspect engine voices and locale defaults.
For `OpenAiTtsEngine`, the available voices are determined by a built-in
model-scoped catalog (different models support different voice sets). You can
supply per-model overrides via `voiceCatalogOverrides`.

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
  output: NullOutput(),
 );
 
 await service.init();
 service.preferredFormat = TtsAudioFormat.wav;
 service.sampleRateHz = 24000;

 final chunks = await service
   .speak('hello-1', 'Hello from flutter uni tts')
   .toList();

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
      audioSpec: const TtsAudioSpec(format: TtsAudioFormat.mp3),
    ),
    chunkSizeBytes: 3,
    maxBytesPerSecond: 8000,
  );

  final chunks = await engine
      .synthesize(
        const TtsRequest(requestId: 'raw-1', text: 'ignored input text'),
        SynthesisControl(),
        const TtsAudioSpec(format: TtsAudioFormat.mp3),
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
    const TtsRequest(requestId: 'mp3-1', text: 'ignored input text'),
    SynthesisControl(),
    const TtsAudioSpec(format: TtsAudioFormat.mp3),
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
        const TtsRequest(requestId: 'wav-1', text: 'ignored'),
        SynthesisControl(),
        const TtsAudioSpec(format: TtsAudioFormat.wav),
      )
      .drain();

  await pcmEngine
      .synthesize(
        const TtsRequest(requestId: 'pcm-1', text: 'ignored'),
        SynthesisControl(),
        const TtsAudioSpec(format: TtsAudioFormat.wav),
      )
      .drain();
}
```

## Example

See example flow in example/main.dart.

By default the example uses SineTtsEngine.
If OPENAI_API_KEY is set, it automatically switches to OpenAiTtsEngine.

Run it with:

```bash
dart run example/main.dart
```

Run with OpenAI mode:

```bash
# PowerShell
$env:OPENAI_API_KEY="your_key_here"
dart run example/main.dart
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
      WaveFileOutput(outputId: 'file', outputDirectory: tempDir),
    ],
    errorPolicy: MulticastOutputErrorPolicy.bestEffort,
  );

  final service = TtsFlow(
    engine: SineTtsEngine(
      engineId: 'fake-engine',
      supportsStreaming: true,
      chunkCount: 3,
    ),
    output: output,
  );

  await service.init();
  service.preferredFormat = TtsAudioFormat.wav;

  await service
      .speak('fanout-1', 'hello fanout')
      .drain();

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

## Development Commands

```bash
dart pub get
dart analyze
dart test
```

## Milestone Tags

Repository checkpoints are tagged as m1 through m6.
