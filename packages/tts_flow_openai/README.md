# tts_flow_openai

Optional OpenAI adapter for `tts_flow_dart`. Add this package only in apps
that use OpenAI TTS, so the core package stays free of HTTP and provider code.

```dart
import 'package:tts_flow_openai/tts_flow_openai.dart';

final engine = OpenAiTtsEngine.fromClientConfig(
  config: const OpenAiClientConfig(apiKey: '...'),
);
```
