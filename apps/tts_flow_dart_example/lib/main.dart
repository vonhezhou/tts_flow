import 'dart:io';

import 'package:tts_flow_dart/tts_flow_dart.dart';
import 'package:tts_flow_mimo/tts_flow_mimo.dart';

Future<void> main() async {
  final mimoApiKey = Platform.environment['MIMO_API_KEY'];
  final useMimo = mimoApiKey != null && mimoApiKey.isNotEmpty;

  final engine = useMimo
      ? MimoTtsEngine(apiKey: mimoApiKey)
      : SineTtsEngine(
          engineId: 'fake-engine',
          supportsStreaming: true,
          chunkCount: 3,
          chunkDelay: const Duration(milliseconds: 5),
        );

  final service = TtsFlow(engine: engine, defaultOutput: NullOutput());

  print(
    useMimo
        ? 'Running example in MiMo mode (MIMO_API_KEY detected).'
        : 'Running example in fake-engine mode (set MIMO_API_KEY for real API calls).',
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

  try {
    await service.init();
    service.preferredFormat = TtsAudioFormat.pcm;
    final first = service.speak(
      'First request uses preferred PCM.',
      utteranceId: 'example-1',
    );
    // chunks 只有一个消费者；每次 speak 后立即订阅，不缓存整段音频。
    final firstDone = reportRequest(first);

    service.preferredFormat = TtsAudioFormat.mp3;
    final second = service.speak(
      'Second request falls back to compatible PCM.',
      utteranceId: 'example-2',
    );
    final secondDone = reportRequest(second);

    await Future.wait([firstDone, secondDone]);
  } finally {
    await queueSub.cancel();
    await requestSub.cancel();
    await service.dispose();
  }
}

Future<void> reportRequest(TtsRequestHandle request) async {
  var audioChunks = 0;
  var audioBytes = 0;
  try {
    await for (final chunk in request.chunks) {
      // 语义元数据块不计入音频统计。
      if (chunk is TtsAudioChunk) {
        audioChunks++;
        audioBytes += chunk.bytes.length;
      }
    }
  } catch (error) {
    stderr.writeln('${request.utteranceId} chunk stream failed: $error');
  }

  // 流结束不等于输出写入成功，以 synthesisResult 判断终态。
  switch (await request.synthesisResult) {
    case TtsSynthesisCompletedResult(:final artifact):
      print(
        '${request.utteranceId} completed: '
        'format=${artifact.audioSpec.format.name} '
        'audioChunks=$audioChunks audioBytes=$audioBytes',
      );
    case TtsSynthesisStoppedResult(:final reason):
      stderr.writeln('${request.utteranceId} stopped: ${reason.name}');
      exitCode = 1;
    case TtsSynthesisFailedResult(:final error):
      stderr.writeln('${request.utteranceId} failed: $error');
      exitCode = 1;
  }
}
