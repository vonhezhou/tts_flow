# tts_flow_gemini

Pure Dart Gemini text-to-speech adapter for `tts_flow_dart` and Flutter. Uses
the maintained community SDK [`googleai_dart`](https://pub.dev/packages/googleai_dart)
13.x for authentication, typed requests, SSE parsing, and response decoding.
The 13.0 upgrade retains the synthesis API and raises the package's minimum
Dart version to 3.12, matching the SDK requirement. CI uses Flutter 3.47.8.
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
# Capture a separate 30–60 second sample using a fixed test passage.
dart run packages/tts_flow_gemini/tool/live_contract_check.dart --capture-fixture --long
```

By default these commands send only the fixed phrase `This is a provider fixture.`.
`--long` instead sends the fixed, non-user test passage defined in the capture
tool, saves to `gemini/long_continuous/`, and checks the decoded PCM duration
is between 30 and 60 seconds before writing any fixture. It does not overwrite
the short sample. Out-of-range output fails rather than padding, trimming, or
repeating audio to manufacture the requested duration.
Capture refuses to overwrite an existing fixture. No API key, request headers,
user text, or account metadata is serialized. Timing records adapter emission
after SDK decoding, relative to the first emitted audio chunk; it is not a
record of raw HTTP arrival times. Add the captured directory explicitly to the
Flutter asset list and perform native replay before marking it verified.

The live contract was verified on 2026-10-21 using the default model and voice:
63 chunks, 120960 PCM bytes (2.52 seconds), and valid TtsFlow WAV output.
The sanitized capture is stored under `assets/fixtures/gemini/continuous/` in
the Flutter example; see [capture details](../../docs/provider_playback_fixtures.md).
On 2026-10-22, the same model and voice also produced a 48.40 second long sample:
1210 chunks and 2323200 PCM bytes in `gemini/long_continuous/`.

During this local verification, direct API connections timed out. The existing
local HTTP proxy worked when selected only for the command's environment:

```fish
env https_proxy=http://127.0.0.1:7890 \
  dart run packages/tts_flow_gemini/tool/live_contract_check.dart
```

Use your own proxy address if needed. This setting is optional and is not
hardcoded into the adapter or saved by the capture tool.
