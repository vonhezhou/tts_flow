# tts_flow_mimo

Optional Xiaomi MiMo V2.5 TTS adapter for `tts_flow_dart`.

```dart
import 'package:tts_flow_dart/tts_flow_dart.dart';
import 'package:tts_flow_mimo/tts_flow_mimo.dart';

Future<void> main() async {
  final flow = TtsFlow(
    engine: MimoTtsEngine(apiKey: 'MIMO_API_KEY'),
    defaultOutput: WavFileOutput('speech.wav'),
  );
  await flow.init();
  flow.preferredFormat = TtsAudioFormat.pcm;
  await flow.dispose();
}
```

The adapter uses `https://api.xiaomimimo.com/v1/chat/completions` with
`stream: true` and `audio.format: pcm16`. It exposes 24 kHz, 16-bit, mono PCM.
Use `TtsRequest.params` for MiMo-specific controls:

- `mimoInstruction` (`String`): natural-language style control.
- `mimoVoiceDesignPrompt` (`String`): voice-design prompt when model is
  `mimo-v2.5-tts-voicedesign`.
- `mimoOptimizeTextPreview` (`bool`): MiMo text optimization switch.

For voice cloning, use a `TtsVoice` whose `voiceId` is the documented
`data:audio/...;base64,...` value.

`MimoTtsEngine.requestTimeout` controls the HTTP request deadline (30 seconds
by default). Cancel an active request through its `TtsRequestHandle`.
