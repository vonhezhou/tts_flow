import 'package:flutter_uni_tts/flutter_uni_tts.dart';

Future<void> main() async {
  final service = TtsService(
    engine: FakeTtsEngine(
      engineId: 'fake-engine',
      supportsStreaming: true,
      chunkCount: 3,
      chunkDelay: const Duration(milliseconds: 5),
    ),
    output: MemoryOutput(),
  );

  final queueSub = service.queueEvents.listen((event) {
    print(
        'queue: ${event.type} len=${event.queueLength} req=${event.requestId}');
  });
  final requestSub = service.requestEvents.listen((event) {
    print('request: ${event.type} req=${event.requestId}');
  });

  final first = service.speak(
    const TtsRequest(
      requestId: 'example-1',
      text: 'First request uses preferred WAV.',
      preferredFormat: TtsAudioFormat.wav,
    ),
  );

  final second = service.speak(
    const TtsRequest(
      requestId: 'example-2',
      text: 'Second request falls back to compatible format.',
    ),
  );

  final firstChunks = await first.toList();
  final secondChunks = await second.toList();

  print('first chunks: ${firstChunks.length}');
  print('second chunks: ${secondChunks.length}');

  await queueSub.cancel();
  await requestSub.cancel();
  await service.dispose();
}
