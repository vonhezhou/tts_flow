# tts_flow_dart

tts_flow_dart is a clean, extensible TTS framework for Dart and Flutter.

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
  - MemoryOutput
  - FileOutput
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
  engine: FakeTtsEngine(
   engineId: 'fake-engine',
   supportsStreaming: true,
   chunkCount: 3,
  ),
  output: MemoryOutput(),
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

## Example

See example flow in example/main.dart.

By default the example uses FakeTtsEngine.
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
outputs such as memory and file at the same time.

```dart
import 'dart:io';

import 'package:tts_flow_dart/tts_flow_dart.dart';

Future<void> main() async {
  final tempDir = await Directory.systemTemp.createTemp('uni_tts_fanout_');

  final output = MulticastOutput(
    outputs: [
      MemoryOutput(outputId: 'memory'),
      FileOutput(outputId: 'file', outputDirectory: tempDir),
    ],
    errorPolicy: MulticastOutputErrorPolicy.bestEffort,
  );

  final service = TtsFlow(
    engine: FakeTtsEngine(
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
