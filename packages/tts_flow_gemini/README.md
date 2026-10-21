# tts_flow_gemini

Pure Dart Gemini text-to-speech adapter for `tts_flow_dart` and Flutter. Uses
the maintained community SDK [`googleai_dart`](https://pub.dev/packages/googleai_dart)
12.x for authentication, typed requests, SSE parsing, and response decoding.
Version 13 requires Dart 3.12, while this workspace supports Dart 3.11.
The deprecated `google_generative_ai` package is not used. Google's official
[`firebase_ai`](https://firebase.google.com/docs/ai-logic/generate-speech) is
another option for Flutter apps already configured with Firebase; this adapter
requires only a Gemini Developer API key and no Firebase project setup.

The default model is `gemini-3.1-flash-tts-preview`, with prebuilt voice `Kore`.
It uses `streamGenerateContent`, emitting **24 kHz, 16-bit, mono signed
little-endian PCM** through `TtsFlow`. This adapter targets the Gemini 3.1
prebuilt-voice schema; newer model IDs are not assumed wire-compatible.
It rejects unexpected encodings, incomplete streams and abnormal finish
reasons. Requests are not automatically retried. Header and idle HTTP chunk
deadlines default to 45 seconds. Cancellation is checked on SDK responses;
it does not promise immediate upstream abort during an idle response.

```dart
import 'package:tts_flow_dart/tts_flow_dart.dart';
import 'package:tts_flow_gemini/tts_flow_gemini.dart';

Future<void> synthesize(String apiKey) async {
  final flow = TtsFlow(
    engine: GeminiTtsEngine(apiKey: apiKey),
    defaultOutput: WavFileOutput('speech.wav'),
  );
  try {
    await flow.init();
    final handle = flow.speak('你好，TtsFlow。');
    await handle.chunks.drain<void>();
  } finally {
    await flow.dispose();
  }
}
```

`getAvailableVoices` returns a curated multilingual subset (`Kore`, `Puck`,
`Zephyr`), not a provider-fetched catalog. Other documented prebuilt voice IDs
can be supplied in `TtsRequest.voice`. Numeric speed/pitch controls and
multi-speaker output are not advertised. Natural-language delivery directions
can be included in the 3.1 model's text prompt.

## Offline checks

From the repository root:

```sh
dart test packages/tts_flow_gemini/test
cd apps/tts_flow_flutter_example
flutter test integration_test/just_audio_jitter_test.dart -d macos
```

Tests run the actual SDK against mock HTTP streams, exercise TtsFlow WAV
writing, and replay the existing MiMo PCM bytes inside simulated Gemini SSE
events through the native speaker. They never contact Google. The reused
audio is not presented as a captured Gemini response.

## Optional live check and fixture capture

Create a key in [Google AI Studio](https://aistudio.google.com/apikey). The
model has a [free tier](https://ai.google.dev/gemini-api/docs/pricing), subject
to account/model quotas and [supported regions](https://ai.google.dev/gemini-api/docs/available-regions).
This does not guarantee that a particular account has available quota.
With an exported `GEMINI_API_KEY`, run from the repository root:

```sh
dart run packages/tts_flow_gemini/tool/live_contract_check.dart
# Optional: also save sanitized audio chunks and adapter-output timing.
dart run packages/tts_flow_gemini/tool/live_contract_check.dart --capture-fixture
```

These commands send only the fixed phrase `This is a provider fixture.`.
Capture refuses to overwrite an existing fixture. No API key, request headers,
user text, or account metadata is serialized. Timing records adapter emission
after SDK decoding, relative to the first emitted audio chunk; it is not a
record of raw HTTP arrival times. Add the captured directory explicitly to the
Flutter asset list and perform native replay before marking it verified.

No live Gemini request or Gemini audio capture has been verified as part of
the initial offline integration.
