import 'dart:io';

import 'package:tts_flow_dart/tts_flow_dart.dart';
import 'package:tts_flow_mimo/tts_flow_mimo.dart';
import 'package:tts_flow_openai/tts_flow_openai.dart';

Future<void> main() async {
  final apiKey = Platform.environment['OPENAI_API_KEY'];
  final useOpenAi = apiKey != null && apiKey.isNotEmpty;
  final mimoApiKey = Platform.environment['MIMO_API_KEY'];
  final useMimo = mimoApiKey != null && mimoApiKey.isNotEmpty;

  final engine = useMimo
      ? MimoTtsEngine(apiKey: mimoApiKey)
      : useOpenAi
      ? OpenAiTtsEngine.fromClientConfig(
          config: OpenAiClientConfig(
            apiKey: apiKey,
            maxRetries: 2,
            initialBackoff: const Duration(milliseconds: 250),
          ),
        )
      : SineTtsEngine(
          engineId: 'fake-engine',
          supportsStreaming: true,
          chunkCount: 3,
          chunkDelay: const Duration(milliseconds: 5),
        );

  final service = TtsFlow(engine: engine, defaultOutput: NullOutput());
  await service.init();

  print(
    useMimo
        ? 'Running example in MiMo mode (MIMO_API_KEY detected).'
        : useOpenAi
        ? 'Running example in OpenAI mode (OPENAI_API_KEY detected).'
        : 'Running example in fake-engine mode (set MIMO_API_KEY or OPENAI_API_KEY for real API calls).',
  );

  final queueSub = service.queueEvents.listen((event) {
    print(
      'queue: ${event.type} len=${event.queueLength} '
      'key=${event.requestKey} utterance=${event.utteranceId}',
    );
  });
  final requestSub = service.requestEvents.listen((event) {
    print(
      'request: ${event.type} key=${event.requestKey} '
      'utterance=${event.utteranceId}',
    );
  });

  service.preferredFormat = TtsAudioFormat.pcm;
  final first = service.speak(
    'First request uses preferred WAV.',
    utteranceId: 'example-1',
  );

  service.preferredFormat = TtsAudioFormat.mp3;
  final second = service.speak(
    'Second request falls back to compatible format.',
    utteranceId: 'example-2',
  );

  final firstChunks = await first.chunks.toList();
  final secondChunks = await second.chunks.toList();

  print('first chunks: ${firstChunks.length}');
  print('second chunks: ${secondChunks.length}');

  await queueSub.cancel();
  await requestSub.cancel();
  await service.dispose();
}
