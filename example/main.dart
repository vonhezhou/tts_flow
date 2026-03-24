import 'dart:io';

import 'package:flutter_uni_tts/flutter_uni_tts.dart';

Future<void> main() async {
  final apiKey = Platform.environment['OPENAI_API_KEY'];
  final useOpenAi = apiKey != null && apiKey.isNotEmpty;

  final engine = useOpenAi
      ? OpenAiTtsEngine.fromClientConfig(
          config: OpenAiClientConfig(
            apiKey: apiKey,
            maxRetries: 2,
            initialBackoff: const Duration(milliseconds: 250),
          ),
        )
      : FakeTtsEngine(
          engineId: 'fake-engine',
          supportsStreaming: true,
          chunkCount: 3,
          chunkDelay: const Duration(milliseconds: 5),
        );

  final service = TtsService(
    engine: engine,
    output: MemoryOutput(),
  );
  await service.init();

  print(
    useOpenAi
        ? 'Running example in OpenAI mode (OPENAI_API_KEY detected).'
        : 'Running example in fake-engine mode (set OPENAI_API_KEY for real API calls).',
  );

  final queueSub = service.queueEvents.listen((event) {
    print(
        'queue: ${event.type} len=${event.queueLength} req=${event.requestId}');
  });
  final requestSub = service.requestEvents.listen((event) {
    print('request: ${event.type} req=${event.requestId}');
  });

  service.preferredFormat = TtsAudioFormat.wav;
  final first = service.speak('example-1', 'First request uses preferred WAV.');

  service.preferredFormat = TtsAudioFormat.mp3;
  final second = service.speak(
      'example-2', 'Second request falls back to compatible format.');

  final firstChunks = await first.toList();
  final secondChunks = await second.toList();

  print('first chunks: ${firstChunks.length}');
  print('second chunks: ${secondChunks.length}');

  await queueSub.cancel();
  await requestSub.cancel();
  await service.dispose();
}
