# tts_flow_azure

Optional Azure AI Speech adapter for `tts_flow_dart`. It uses the Azure Speech
REST API, sends SSML, and streams 24 kHz / 48 kbps mono MP3 response bytes.

```dart
import 'package:tts_flow_azure/tts_flow_azure.dart';

final flow = TtsFlow(
  engine: AzureSpeechTtsEngine(
    config: const AzureSpeechConfig(
      subscriptionKey: 'AZURE_SPEECH_KEY',
      region: 'eastasia',
    ),
  ),
  defaultOutput: speakerOutput,
);
await flow.init();
flow.preferredFormat = TtsAudioFormat.mp3;
```

`getAvailableVoices()` fetches and caches Azure's voice list for the configured
region. The configured `defaultVoiceId` is used without a network call during
`TtsFlow.init()`, then the real catalog is fetched when the UI asks for voices.

Do not ship a resource key in a production client. Use a backend-issued token,
or keep the key in a development-only `--dart-define` as the Flutter example
does. Azure's REST API is region-specific: choose the same region as the Speech
resource (for example `eastasia`).
