# flutter_uni_tts

flutter_uni_tts is a clean, extensible TTS framework for Dart and Flutter.

Core design choices in this repository:

- Fixed service wiring: each TtsService instance uses one engine and one output.
- Request-scoped format negotiation: format is resolved per request.
- Unified API: speak always returns Stream<TtsChunk>.
- FIFO queue semantics with halt-on-failure behavior.

## Current Feature Set

- Pluggable engine contract via TtsEngine.
- Pluggable output contract via TtsOutput.
- Built-in outputs:
  - MemoryOutput
  - FileOutput
  - CompositeOutput (fanout to multiple outputs)
  - SpeakerOutput (backend abstraction baseline)
- Built-in adapters/utilities:
  - TtsFormatNegotiator
  - NonStreamingBridge
  - OpenAiTtsEngine transport adapter API
- Queue orchestration and controls:
  - speak
  - pauseCurrent
  - resumeCurrent
  - stopCurrent
  - clearQueue

## Quick Start

```dart
import 'package:flutter_uni_tts/flutter_uni_tts.dart';

Future<void> main() async {
 final service = TtsService(
  engine: FakeTtsEngine(
   engineId: 'fake-engine',
   supportsStreaming: true,
   chunkCount: 3,
  ),
  output: MemoryOutput(),
 );

 final chunks = await service
   .speak(
    const TtsRequest(
     requestId: 'hello-1',
     text: 'Hello from flutter uni tts',
     preferredFormat: TtsAudioFormat.wav,
    ),
   )
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

## CompositeOutput (Multi-output Fanout)

Use `CompositeOutput` when you want one synthesis request to write to multiple
outputs such as memory and file at the same time.

```dart
import 'dart:io';

import 'package:flutter_uni_tts/flutter_uni_tts.dart';

Future<void> main() async {
  final tempDir = await Directory.systemTemp.createTemp('uni_tts_fanout_');

  final output = CompositeOutput(
    outputs: [
      MemoryOutput(outputId: 'memory'),
      FileOutput(outputId: 'file', outputDirectory: tempDir),
    ],
    errorPolicy: CompositeOutputErrorPolicy.bestEffort,
  );

  final service = TtsService(
    engine: FakeTtsEngine(
      engineId: 'fake-engine',
      supportsStreaming: true,
      chunkCount: 3,
    ),
    output: output,
  );

  await service
      .speak(
        const TtsRequest(
          requestId: 'fanout-1',
          text: 'hello fanout',
          preferredFormat: TtsAudioFormat.wav,
        ),
      )
      .drain();

  await service.dispose();
}
```

Policy options:

- `CompositeOutputErrorPolicy.bestEffort` (default): failing outputs are
  dropped and remaining outputs continue.
- `CompositeOutputErrorPolicy.failFast`: first output failure aborts the
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
