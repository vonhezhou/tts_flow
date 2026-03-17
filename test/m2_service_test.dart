import 'dart:async';

import 'package:flutter_uni_tts/flutter_uni_tts.dart';
import 'package:test/test.dart';

void main() {
  group('M2 service', () {
    test('processes requests in FIFO order', () async {
      final service = TtsService(
        engine: FakeTtsEngine(
          engineId: 'fake-engine',
          supportsStreaming: true,
          chunkCount: 2,
          chunkDelay: const Duration(milliseconds: 5),
        ),
        output: FakeTtsOutput(),
      );

      final started = <String>[];
      final sub = service.requestEvents.listen((event) {
        if (event.type == TtsRequestEventType.requestStarted) {
          started.add(event.requestId);
        }
      });

      final streamA = service.speak(
        const TtsRequest(requestId: 'a', text: 'first request payload'),
      );
      final streamB = service.speak(
        const TtsRequest(requestId: 'b', text: 'second request payload'),
      );

      await streamA.toList();
      await streamB.toList();
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(started, ['a', 'b']);
      await sub.cancel();
      await service.dispose();
    });

    test('clearQueue cancels pending requests only', () async {
      final service = TtsService(
        engine: FakeTtsEngine(
          engineId: 'fake-engine',
          supportsStreaming: true,
          chunkCount: 3,
          chunkDelay: const Duration(milliseconds: 10),
        ),
        output: FakeTtsOutput(),
      );

      final active = service.speak(
        const TtsRequest(requestId: 'active', text: 'active request'),
      );
      final pending = service.speak(
        const TtsRequest(requestId: 'pending', text: 'pending request'),
      );

      await Future<void>.delayed(const Duration(milliseconds: 8));
      final clearedCount = await service.clearQueue();

      expect(clearedCount, 1);
      expect(await active.toList(), isNotEmpty);
      expect(await pending.toList(), isEmpty);

      await service.dispose();
    });

    test('stopCurrent stops active request and next request proceeds',
        () async {
      final service = TtsService(
        engine: FakeTtsEngine(
          engineId: 'fake-engine',
          supportsStreaming: true,
          chunkCount: 8,
          chunkDelay: const Duration(milliseconds: 5),
        ),
        output: FakeTtsOutput(),
      );

      final events = <TtsRequestEvent>[];
      final sub = service.requestEvents.listen(events.add);

      final longStream = service.speak(
        const TtsRequest(
            requestId: 'long', text: 'this is a long request payload'),
      );
      final nextStream = service.speak(
        const TtsRequest(requestId: 'next', text: 'next request'),
      );

      await Future<void>.delayed(const Duration(milliseconds: 12));
      await service.stopCurrent();

      await longStream.toList();
      await nextStream.toList();

      expect(
        events.any(
          (event) =>
              event.requestId == 'long' &&
              event.type == TtsRequestEventType.requestStopped,
        ),
        isTrue,
      );

      final nextStartedIndex = events.indexWhere(
        (event) =>
            event.requestId == 'next' &&
            event.type == TtsRequestEventType.requestStarted,
      );
      expect(nextStartedIndex, isNonNegative);

      await sub.cancel();
      await service.dispose();
    });
  });
}
