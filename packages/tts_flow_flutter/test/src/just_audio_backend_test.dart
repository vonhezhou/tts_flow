import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:mocktail/mocktail.dart';
import 'package:tts_flow_dart/tts_flow_dart.dart';
import 'package:tts_flow_flutter/src/just_audio/chunk_audio_source.dart';
import 'package:tts_flow_flutter/src/just_audio/just_audio_backend.dart';

class _MockAudioPlayer extends Mock implements AudioPlayer {}

class _FakeAudioSource extends Fake implements AudioSource {}

TtsAudioChunk _audioChunk({
  required String requestKey,
  required int sequenceNumber,
  required List<int> bytes,
  TtsAudioSpec audioSpec = const TtsAudioSpec.mp3(),
}) {
  return TtsAudioChunk(
    bytes: Uint8List.fromList(bytes),
    requestKey: requestKey,
    sequenceNumber: sequenceNumber,
    isLastChunk: false,
    timestamp: DateTime.now(),
    audioSpec: audioSpec,
  );
}

void main() {
  setUpAll(() {
    registerFallbackValue(_FakeAudioSource());
  });

  group('JustAudioBackend', () {
    late _MockAudioPlayer player;
    late StreamController<ProcessingState> processingController;
    late StreamController<Duration?> durationController;
    late StreamController<int?> indexController;
    Duration? nativeDuration;
    late StreamController<Duration> positionController;
    late StreamController<PlayerException> errorController;
    late List<AudioSource> sources;
    late bool playing;
    late ProcessingState processingState;
    int? currentIndex;

    setUp(() {
      player = _MockAudioPlayer();
      processingController = StreamController<ProcessingState>.broadcast();
      durationController = StreamController<Duration?>.broadcast();
      indexController = StreamController<int?>.broadcast();
      nativeDuration = null;
      positionController = StreamController<Duration>.broadcast();
      errorController = StreamController<PlayerException>.broadcast();
      sources = <AudioSource>[];
      playing = false;
      processingState = ProcessingState.idle;
      currentIndex = null;

      when(
        () => player.processingStateStream,
      ).thenAnswer((_) => processingController.stream);
      when(
        () => player.durationStream,
      ).thenAnswer((_) => durationController.stream);
      when(
        () => player.positionStream,
      ).thenAnswer((_) => positionController.stream);
      when(() => player.errorStream).thenAnswer((_) => errorController.stream);
      when(() => player.audioSources).thenAnswer((_) => sources);
      when(() => player.playing).thenAnswer((_) => playing);
      when(() => player.processingState).thenAnswer((_) => processingState);
      when(() => player.currentIndex).thenAnswer((_) => currentIndex);
      when(() => player.duration).thenAnswer((_) => nativeDuration);
      when(
        () => player.currentIndexStream,
      ).thenAnswer((_) => indexController.stream);

      when(() => player.addAudioSource(any())).thenAnswer((invocation) async {
        final source = invocation.positionalArguments.first as AudioSource;
        sources.add(source);
      });
      when(() => player.play()).thenAnswer((_) async {
        playing = true;
      });
      when(() => player.pause()).thenAnswer((_) async {
        playing = false;
      });
      when(() => player.seek(any(), index: any(named: 'index'))).thenAnswer((
        invocation,
      ) async {
        currentIndex = invocation.namedArguments[#index] as int?;
      });
      when(() => player.seekToNext()).thenAnswer((_) async {
        if (currentIndex != null && currentIndex! < sources.length - 1) {
          currentIndex = currentIndex! + 1;
        }
      });
      when(() => player.stop()).thenAnswer((_) async {
        playing = false;
      });
      when(() => player.clearAudioSources()).thenAnswer((_) async {
        sources.clear();
        currentIndex = null;
      });
      when(
        () => player.removeAudioSourceRange(any(), any()),
      ).thenAnswer((invocation) async {
        final start = invocation.positionalArguments[0] as int;
        final endExclusive = invocation.positionalArguments[1] as int;
        sources.removeRange(start, endExclusive);
      });
      when(() => player.dispose()).thenAnswer((_) async {});
    });

    tearDown(() async {
      await processingController.close();
      await durationController.close();
      await indexController.close();
      await positionController.close();
      await errorController.close();
    });

    for (final spec in [
      const TtsAudioSpec.aac(),
      const TtsAudioSpec.opus(),
      const TtsAudioSpec.mp3(),
    ]) {
      test(
        'buffered ${spec.format.name} keeps all fragments until finalize',
        () async {
          final backend = JustAudioBackend.testing(
            player: player,
            bufferEncodedAudio: true,
          );
          addTearDown(backend.dispose);
          final id = await backend.startPlayback(
            requestKey: 'buffered',
            audioSpec: spec,
          );
          final first = _audioChunk(
            requestKey: 'buffered',
            sequenceNumber: 0,
            bytes: [1],
            audioSpec: spec,
          );
          await backend.appendChunk(playbackId: id, chunk: first);
          first.bytes[0] = 99;
          await backend.appendChunk(
            playbackId: id,
            chunk: _audioChunk(
              requestKey: 'buffered',
              sequenceNumber: 1,
              bytes: [2, 3],
              audioSpec: spec,
            ),
          );
          expect(sources, isEmpty);
          verifyNever(() => player.play());
          await backend.finalizePlayback(playbackId: id);
          final source = sources.single as ChunkAudioSource;
          final response = await source.request();
          expect(await response.stream.expand((bytes) => bytes).toList(), [
            1,
            2,
            3,
          ]);
          expect(response.contentLength, 3);
          expect(response.contentType, spec.format.mimeType);
          expect(source.isTerminalSegment, isTrue);
          await backend.finalizePlayback(playbackId: id);
          expect(sources, hasLength(1));
          verify(() => player.play()).called(1);
          await expectLater(
            backend.appendChunk(playbackId: id, chunk: first),
            throwsStateError,
          );
        },
      );
    }

    test(
      'buffer limit rejects excess bytes without submitting partial audio',
      () async {
        final backend = JustAudioBackend.testing(
          player: player,
          bufferEncodedAudio: true,
          maxBufferedEncodedBytes: 2,
        );
        addTearDown(backend.dispose);
        final id = await backend.startPlayback(
          requestKey: 'limited',
          audioSpec: const TtsAudioSpec.aac(),
        );
        await backend.appendChunk(
          playbackId: id,
          chunk: _audioChunk(
            requestKey: 'limited',
            sequenceNumber: 0,
            bytes: [1, 2],
            audioSpec: const TtsAudioSpec.aac(),
          ),
        );
        await expectLater(
          backend.appendChunk(
            playbackId: id,
            chunk: _audioChunk(
              requestKey: 'limited',
              sequenceNumber: 1,
              bytes: [3],
              audioSpec: const TtsAudioSpec.aac(),
            ),
          ),
          throwsStateError,
        );
        expect(sources, isEmpty);
        await expectLater(
          backend.finalizePlayback(playbackId: id),
          throwsStateError,
        );
        await backend.stopPlayback(playbackId: id);
        verifyNever(() => player.play());
      },
    );

    test(
      'stopping buffered audio discards it before native playback',
      () async {
        final backend = JustAudioBackend.testing(
          player: player,
          bufferEncodedAudio: true,
        );
        addTearDown(backend.dispose);
        final id = await backend.startPlayback(
          requestKey: 'canceled',
          audioSpec: const TtsAudioSpec.opus(),
        );
        await backend.appendChunk(
          playbackId: id,
          chunk: _audioChunk(
            requestKey: 'canceled',
            sequenceNumber: 0,
            bytes: [1, 2],
            audioSpec: const TtsAudioSpec.opus(),
          ),
        );
        await backend.stopPlayback(playbackId: id);
        await expectLater(
          backend.finalizePlayback(playbackId: id),
          throwsStateError,
        );
        expect(sources, isEmpty);
        verifyNever(() => player.play());
      },
    );

    test('buffer option preserves progressive PCM playback', () async {
      final backend = JustAudioBackend.testing(
        player: player,
        bufferEncodedAudio: true,
      );
      addTearDown(backend.dispose);
      const spec = TtsAudioSpec.pcm(PcmDescriptor.s16Mono24KHz());
      final id = await backend.startPlayback(
        requestKey: 'pcm',
        audioSpec: spec,
      );
      await backend.appendChunk(
        playbackId: id,
        chunk: _audioChunk(
          requestKey: 'pcm',
          sequenceNumber: 0,
          bytes: [1, 2],
          audioSpec: spec,
        ),
      );
      expect(sources, hasLength(1));
      verify(() => player.play()).called(1);
    });

    test(
      'source becomes terminal only when playback is finalized',
      () async {
        final backend = JustAudioBackend.testing(player: player);
        addTearDown(backend.dispose);

        final firstPlaybackId = await backend.startPlayback(
          requestKey: 'r1',
          audioSpec: const TtsAudioSpec.mp3(),
        );

        await backend.appendChunk(
          playbackId: firstPlaybackId,
          chunk: TtsAudioChunk(
            bytes: Uint8List.fromList([1, 2, 3]),
            requestKey: '',
            sequenceNumber: 0,
            isLastChunk: false,
            timestamp: DateTime.now(),
            audioSpec: const TtsAudioSpec.mp3(),
          ),
        );
        expect(sources, hasLength(1));

        final firstSource = sources.first as ChunkAudioSource;
        expect(firstSource.playbackId, firstPlaybackId);
        expect(firstSource.isTerminalSegment, isFalse);

        await backend.finalizePlayback(playbackId: firstPlaybackId);
        expect(firstSource.isTerminalSegment, isTrue);

        final secondPlaybackId = await backend.startPlayback(
          requestKey: 'r2',
          audioSpec: const TtsAudioSpec.mp3(),
        );
        await backend.appendChunk(
          playbackId: secondPlaybackId,
          chunk: TtsAudioChunk(
            bytes: Uint8List.fromList([9]),
            requestKey: '',
            sequenceNumber: 0,
            isLastChunk: true,
            timestamp: DateTime.now(),
            audioSpec: const TtsAudioSpec.mp3(),
          ),
        );

        expect(sources, hasLength(2));
        final secondSource = sources[1] as ChunkAudioSource;
        expect(identical(firstSource, secondSource), isFalse);
        expect(secondSource.playbackId, secondPlaybackId);
        expect(firstSource.playbackId, firstPlaybackId);
      },
    );

    test('does not block chunk ingestion on the play Future', () async {
      final playCompleter = Completer<void>();
      when(() => player.play()).thenAnswer((_) => playCompleter.future);
      final backend = JustAudioBackend.testing(player: player);
      addTearDown(() async {
        playCompleter.complete();
        await backend.dispose();
      });

      final playbackId = await backend.startPlayback(
        requestKey: 'non-blocking-play',
        audioSpec: const TtsAudioSpec.mp3(),
      );
      await backend
          .appendChunk(
            playbackId: playbackId,
            chunk: _audioChunk(
              requestKey: 'non-blocking-play',
              sequenceNumber: 0,
              bytes: [1, 2],
            ),
          )
          .timeout(const Duration(milliseconds: 100));

      expect(sources, hasLength(1));
      verify(() => player.play()).called(1);
    });

    test('stopPlayback is idempotent after an asynchronous cleanup', () async {
      final backend = JustAudioBackend.testing(player: player);
      addTearDown(backend.dispose);

      await backend.stopPlayback(playbackId: 'already-removed');
    });

    test(
      'recovers after controlled source-list underflow and completes once',
      () async {
        final backend = JustAudioBackend.testing(player: player);
        addTearDown(backend.dispose);

        final events = <SpeakerPlaybackCompletedEvent>[];
        final sub = backend.playbackCompletedEvents.listen(events.add);
        addTearDown(sub.cancel);
        final waitingEvents = <JustAudioPlaybackWaitingEvent>[];
        final waitingSub = backend.playbackWaitingStream.listen(
          waitingEvents.add,
        );
        addTearDown(waitingSub.cancel);
        final sourceStartedEvents = <JustAudioPlaybackSourceStartedEvent>[];
        final sourceStartedSub = backend.playbackSourceStartedStream.listen(
          sourceStartedEvents.add,
        );
        addTearDown(sourceStartedSub.cancel);

        final playbackId = await backend.startPlayback(
          requestKey: 'r1',
          audioSpec: const TtsAudioSpec.mp3(),
        );
        await backend.appendChunk(
          playbackId: playbackId,
          chunk: TtsAudioChunk(
            bytes: Uint8List.fromList([1, 2]),
            requestKey: 'r1',
            sequenceNumber: 0,
            isLastChunk: false,
            timestamp: DateTime.now(),
            audioSpec: const TtsAudioSpec.mp3(),
          ),
        );

        final firstSource = sources.single as ChunkAudioSource;
        await firstSource.request();
        expect(sourceStartedEvents, hasLength(1));
        expect(sourceStartedEvents.single.playbackId, playbackId);
        expect(sourceStartedEvents.single.sourceIndex, 0);
        currentIndex = 0;
        processingState = ProcessingState.completed;
        playing = false;
        processingController.add(ProcessingState.completed);
        await Future<void>.delayed(Duration.zero);

        expect(events, isEmpty);
        expect(sources, hasLength(1));
        expect(waitingEvents, hasLength(1));
        expect(waitingEvents.single.playbackId, playbackId);
        expect(waitingEvents.single.sourceIndex, 0);

        await backend.appendChunk(
          playbackId: playbackId,
          chunk: TtsAudioChunk(
            bytes: Uint8List.fromList([3, 4]),
            requestKey: 'r1',
            sequenceNumber: 1,
            isLastChunk: true,
            timestamp: DateTime.now(),
            audioSpec: const TtsAudioSpec.mp3(),
          ),
        );

        expect(sources, hasLength(2));
        expect(currentIndex, 1);
        expect(playing, isTrue);

        await backend.finalizePlayback(playbackId: playbackId);
        processingState = ProcessingState.completed;
        processingController.add(ProcessingState.completed);
        await Future<void>.delayed(Duration.zero);

        expect(events, hasLength(1));
        expect(events.single.playbackId, playbackId);
        expect(waitingEvents, hasLength(1));
        expect(sources, isEmpty);
      },
    );

    test(
      'keeps the next segment queued without a waiting event when supply '
      'remains continuous',
      () async {
        final backend = JustAudioBackend.testing(player: player);
        addTearDown(backend.dispose);

        final waitingEvents = <JustAudioPlaybackWaitingEvent>[];
        final waitingSub = backend.playbackWaitingStream.listen(
          waitingEvents.add,
        );
        addTearDown(waitingSub.cancel);
        final completedEvents = <SpeakerPlaybackCompletedEvent>[];
        final completedSub = backend.playbackCompletedEvents.listen(
          completedEvents.add,
        );
        addTearDown(completedSub.cancel);

        final playbackId = await backend.startPlayback(
          requestKey: 'continuous',
          audioSpec: const TtsAudioSpec.mp3(),
        );
        await backend.appendChunk(
          playbackId: playbackId,
          chunk: _audioChunk(
            requestKey: 'continuous',
            sequenceNumber: 0,
            bytes: [1, 2],
          ),
        );
        final firstSource = sources.single as ChunkAudioSource;
        await firstSource.request();

        await backend.appendChunk(
          playbackId: playbackId,
          chunk: _audioChunk(
            requestKey: 'continuous',
            sequenceNumber: 1,
            bytes: [3, 4],
          ),
        );
        expect(sources, hasLength(2));
        expect(waitingEvents, isEmpty);

        await backend.finalizePlayback(playbackId: playbackId);
        currentIndex = 1;
        processingState = ProcessingState.completed;
        playing = false;
        processingController.add(ProcessingState.completed);
        await Future<void>.delayed(Duration.zero);

        expect(waitingEvents, isEmpty);
        expect(completedEvents, hasLength(1));
        expect(completedEvents.single.playbackId, playbackId);
      },
    );

    test(
      'stopPlayback throws when playlist has non-ChunkAudioSource',
      () async {
        final backend = JustAudioBackend.testing(player: player);
        addTearDown(backend.dispose);

        final playbackId = await backend.startPlayback(
          requestKey: 'r1',
          audioSpec: const TtsAudioSpec.mp3(),
        );
        await backend.appendChunk(
          playbackId: playbackId,
          chunk: TtsAudioChunk(
            bytes: Uint8List.fromList([1]),
            requestKey: '',
            sequenceNumber: 0,
            isLastChunk: false,
            timestamp: DateTime.now(),
            audioSpec: const TtsAudioSpec.mp3(),
          ),
        );

        sources.add(_FakeAudioSource());

        await expectLater(
          () => backend.stopPlayback(playbackId: playbackId),
          throwsStateError,
        );
      },
    );

    test('emits and cleans up an attributed platform playback error', () async {
      final backend = JustAudioBackend.testing(player: player);
      addTearDown(backend.dispose);

      final events = <JustAudioPlaybackErrorEvent>[];
      final sub = backend.playbackErrorStream.listen(events.add);
      addTearDown(sub.cancel);
      final backendFailureEvents = <SpeakerPlaybackFailedEvent>[];
      final backendFailureSub = backend.playbackFailedEvents.listen(
        backendFailureEvents.add,
      );
      addTearDown(backendFailureSub.cancel);

      final playbackId = await backend.startPlayback(
        requestKey: 'r1',
        audioSpec: const TtsAudioSpec.mp3(),
      );
      await backend.appendChunk(
        playbackId: playbackId,
        chunk: TtsAudioChunk(
          bytes: Uint8List.fromList([1, 2]),
          requestKey: 'r1',
          sequenceNumber: 0,
          isLastChunk: false,
          timestamp: DateTime.now(),
          audioSpec: const TtsAudioSpec.mp3(),
        ),
      );

      currentIndex = 0;
      errorController.add(PlayerException(1, 'decode failed', 0));
      await Future<void>.delayed(Duration.zero);

      expect(events, hasLength(1));
      expect(events.single.playbackId, playbackId);
      expect(events.single.requestKey, 'r1');
      expect(events.single.error.message, 'decode failed');
      expect(backendFailureEvents, hasLength(1));
      expect(backendFailureEvents.single.requestKey, 'r1');
      expect(
        backendFailureEvents.single.error.code,
        TtsErrorCode.outputPlaybackFailed,
      );
      expect(sources, isEmpty);
    });

    test('emits playbackCompletedEvents once for terminal segment', () async {
      final backend = JustAudioBackend.testing(player: player);
      addTearDown(backend.dispose);

      final events = <SpeakerPlaybackCompletedEvent>[];
      final sub = backend.playbackCompletedEvents.listen(events.add);
      addTearDown(sub.cancel);

      final playbackId = await backend.startPlayback(
        requestKey: 'r1',
        audioSpec: const TtsAudioSpec.mp3(),
      );
      await backend.appendChunk(
        playbackId: playbackId,
        chunk: TtsAudioChunk(
          bytes: Uint8List.fromList([1, 2]),
          requestKey: '',
          sequenceNumber: 0,
          isLastChunk: false,
          timestamp: DateTime.now(),
          audioSpec: const TtsAudioSpec.mp3(),
        ),
      );
      await backend.finalizePlayback(playbackId: playbackId);

      currentIndex = 0;
      processingController
        ..add(ProcessingState.completed)
        ..add(ProcessingState.completed);
      await Future<void>.delayed(Duration.zero);

      expect(events, hasLength(1));
      expect(events.single.requestKey, 'r1');
      expect(events.single.playbackId, playbackId);
      expect(sources, isEmpty);
      await expectLater(
        () => backend.pausePlayback(playbackId: playbackId),
        throwsStateError,
      );
    });

    test(
      'completion removes finished sources and continues to next playback',
      () async {
        final backend = JustAudioBackend.testing(player: player);
        addTearDown(backend.dispose);

        final firstPlaybackId = await backend.startPlayback(
          requestKey: 'r1',
          audioSpec: const TtsAudioSpec.mp3(),
        );
        await backend.appendChunk(
          playbackId: firstPlaybackId,
          chunk: TtsAudioChunk(
            bytes: Uint8List.fromList([1, 2]),
            requestKey: '',
            sequenceNumber: 0,
            isLastChunk: false,
            timestamp: DateTime.now(),
            audioSpec: const TtsAudioSpec.mp3(),
          ),
        );
        await backend.finalizePlayback(playbackId: firstPlaybackId);

        final secondPlaybackId = await backend.startPlayback(
          requestKey: 'r2',
          audioSpec: const TtsAudioSpec.mp3(),
        );
        await backend.appendChunk(
          playbackId: secondPlaybackId,
          chunk: TtsAudioChunk(
            bytes: Uint8List.fromList([9, 8]),
            requestKey: '',
            sequenceNumber: 0,
            isLastChunk: true,
            timestamp: DateTime.now(),
            audioSpec: const TtsAudioSpec.mp3(),
          ),
        );

        currentIndex = 0;
        playing = true;

        processingController.add(ProcessingState.completed);
        await Future<void>.delayed(Duration.zero);

        expect(sources, hasLength(1));
        final remaining = sources.single as ChunkAudioSource;
        expect(remaining.playbackId, secondPlaybackId);
        expect(currentIndex, 0);
        expect(playing, isTrue);

        await expectLater(
          () => backend.resumePlayback(playbackId: firstPlaybackId),
          throwsStateError,
        );
      },
    );

    test(
      'stop current playback resumes immediately to next playback',
      () async {
        final backend = JustAudioBackend.testing(player: player);
        addTearDown(backend.dispose);

        final firstPlaybackId = await backend.startPlayback(
          requestKey: 'r1',
          audioSpec: const TtsAudioSpec.mp3(),
        );
        await backend.appendChunk(
          playbackId: firstPlaybackId,
          chunk: TtsAudioChunk(
            bytes: Uint8List.fromList([1, 2]),
            requestKey: '',
            sequenceNumber: 0,
            isLastChunk: false,
            timestamp: DateTime.now(),
            audioSpec: const TtsAudioSpec.mp3(),
          ),
        );

        final secondPlaybackId = await backend.startPlayback(
          requestKey: 'r2',
          audioSpec: const TtsAudioSpec.mp3(),
        );
        await backend.appendChunk(
          playbackId: secondPlaybackId,
          chunk: TtsAudioChunk(
            bytes: Uint8List.fromList([9]),
            requestKey: '',
            sequenceNumber: 0,
            isLastChunk: true,
            timestamp: DateTime.now(),
            audioSpec: const TtsAudioSpec.mp3(),
          ),
        );

        expect(sources, hasLength(2));
        currentIndex = 0;
        playing = true;

        await backend.stopPlayback(playbackId: firstPlaybackId);

        expect(sources, hasLength(1));
        final remaining = sources.single as ChunkAudioSource;
        expect(remaining.playbackId, secondPlaybackId);
        expect(currentIndex, 0);
        expect(playing, isTrue);

        verify(() => player.stop()).called(greaterThanOrEqualTo(1));
        verify(
          () => player.seek(Duration.zero, index: 0),
        ).called(greaterThanOrEqualTo(1));
        verify(() => player.play()).called(greaterThanOrEqualTo(1));
      },
    );

    test(
      'equal source durations still advance offsets and total duration',
      () async {
        final backend = JustAudioBackend.testing(player: player);
        addTearDown(backend.dispose);
        final completions = <SpeakerPlaybackCompletedEvent>[];
        final positions = <TtsPlaybackPositionEvent>[];
        final completeSub = backend.playbackCompletedEvents.listen(
          completions.add,
        );
        final positionSub = backend.playbackPositionEvents.listen(
          positions.add,
        );
        addTearDown(completeSub.cancel);
        addTearDown(positionSub.cancel);
        final id = await backend.startPlayback(
          requestKey: 'equal-duration',
          audioSpec: const TtsAudioSpec.mp3(),
        );
        for (var i = 0; i < 3; i++) {
          await backend.appendChunk(
            playbackId: id,
            chunk: _audioChunk(
              requestKey: 'equal-duration',
              sequenceNumber: i,
              bytes: [1, 2],
            ),
          );
          await (sources.last as ChunkAudioSource).request();
          currentIndex = i;
          nativeDuration = const Duration(milliseconds: 320);
          // just_audio.durationStream 使用 distinct，后续相同时长不会再次通知。
          if (i == 0) durationController.add(nativeDuration);
          indexController.add(i);
          await Future<void>.delayed(Duration.zero);
          positionController.add(const Duration(milliseconds: 100));
          await Future<void>.delayed(Duration.zero);
        }
        await backend.finalizePlayback(playbackId: id);
        processingController.add(ProcessingState.completed);
        await Future<void>.delayed(Duration.zero);
        expect(
          completions.single.playedDuration,
          const Duration(milliseconds: 960),
        );
        expect(positions.map((e) => e.position.inMilliseconds), [
          100,
          420,
          740,
        ]);
      },
    );

    test('timeline reporter emits request-scoped positions', () async {
      final backend = JustAudioBackend.testing(player: player);
      addTearDown(backend.dispose);

      final positions = <TtsPlaybackPositionEvent>[];
      final sub = backend.playbackPositionEvents.listen(positions.add);
      addTearDown(sub.cancel);

      final playbackId = await backend.startPlayback(
        requestKey: 'r1',
        audioSpec: const TtsAudioSpec.mp3(),
      );

      await backend.appendChunk(
        playbackId: playbackId,
        chunk: TtsAudioChunk(
          bytes: Uint8List.fromList([1, 2]),
          requestKey: 'r1',
          sequenceNumber: 0,
          isLastChunk: false,
          timestamp: DateTime.now(),
          audioSpec: const TtsAudioSpec.mp3(),
        ),
      );

      currentIndex = 0;
      durationController.add(const Duration(milliseconds: 900));
      await Future<void>.delayed(Duration.zero);
      positionController.add(const Duration(milliseconds: 200));
      await Future<void>.delayed(Duration.zero);

      // Mark first source as started
      // so next append rolls over to a new segment.
      final firstSource = sources.first as ChunkAudioSource;
      await firstSource.request();

      await backend.appendChunk(
        playbackId: playbackId,
        chunk: TtsAudioChunk(
          bytes: Uint8List.fromList([3, 4]),
          requestKey: 'r1',
          sequenceNumber: 1,
          isLastChunk: true,
          timestamp: DateTime.now(),
          audioSpec: const TtsAudioSpec.mp3(),
        ),
      );

      currentIndex = 1;
      durationController.add(const Duration(milliseconds: 600));
      await Future<void>.delayed(Duration.zero);
      positionController.add(const Duration(milliseconds: 100));
      await Future<void>.delayed(Duration.zero);

      expect(positions, [
        isA<TtsPlaybackPositionEvent>()
            .having(
              (event) => event.requestKey,
              'requestKey',
              'r1',
            )
            .having(
              (event) => event.position,
              'position',
              const Duration(milliseconds: 200),
            ),
        isA<TtsPlaybackPositionEvent>()
            .having(
              (event) => event.requestKey,
              'requestKey',
              'r1',
            )
            .having(
              (event) => event.position,
              'position',
              const Duration(milliseconds: 1000),
            ),
      ]);
    });
  });
}
