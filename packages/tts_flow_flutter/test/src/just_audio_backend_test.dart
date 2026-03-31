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

void main() {
  setUpAll(() {
    registerFallbackValue(_FakeAudioSource());
  });

  group('JustAudioBackend', () {
    late _MockAudioPlayer player;
    late StreamController<ProcessingState> processingController;
    late List<AudioSource> sources;
    late bool playing;
    late ProcessingState processingState;
    int? currentIndex;

    setUp(() {
      player = _MockAudioPlayer();
      processingController = StreamController<ProcessingState>.broadcast();
      sources = <AudioSource>[];
      playing = false;
      processingState = ProcessingState.idle;
      currentIndex = null;

      when(
        () => player.processingStateStream,
      ).thenAnswer((_) => processingController.stream);
      when(() => player.audioSources).thenAnswer((_) => sources);
      when(() => player.playing).thenAnswer((_) => playing);
      when(() => player.processingState).thenAnswer((_) => processingState);
      when(() => player.currentIndex).thenAnswer((_) => currentIndex);

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
    });

    test(
      'finalize keeps unstarted tail and next playback uses new source',
      () async {
        final backend = JustAudioBackend.testing(player: player);
        addTearDown(backend.dispose);

        final firstPlaybackId = await backend.startPlayback(
          requestId: 'r1',
          audioSpec: const TtsAudioSpec.mp3(),
        );

        await backend.appendChunk(
          playbackId: firstPlaybackId,
          chunk: TtsAudioChunk(
            bytes: Uint8List.fromList([1, 2, 3]),
            requestId: '',
            sequenceNumber: 0,
            isLastChunk: false,
            timestamp: DateTime.now(),
            audioSpec: const TtsAudioSpec.mp3(),
          ),
        );
        expect(sources, hasLength(1));

        final firstSource = sources.first as ChunkAudioSource;
        expect(firstSource.playbackId, firstPlaybackId);
        expect(firstSource.isTerminalSegment, isTrue);

        await backend.finalizePlayback(playbackId: firstPlaybackId);
        expect(firstSource.isTerminalSegment, isTrue);

        final secondPlaybackId = await backend.startPlayback(
          requestId: 'r2',
          audioSpec: const TtsAudioSpec.mp3(),
        );
        await backend.appendChunk(
          playbackId: secondPlaybackId,
          chunk: TtsAudioChunk(
            bytes: Uint8List.fromList([9]),
            requestId: '',
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

    test(
      'stopPlayback throws when playlist has non-ChunkAudioSource',
      () async {
        final backend = JustAudioBackend.testing(player: player);
        addTearDown(backend.dispose);

        final playbackId = await backend.startPlayback(
          requestId: 'r1',
          audioSpec: const TtsAudioSpec.mp3(),
        );
        await backend.appendChunk(
          playbackId: playbackId,
          chunk: TtsAudioChunk(
            bytes: Uint8List.fromList([1]),
            requestId: '',
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

    test('emits playbackCompletedEvents once for terminal segment', () async {
      final backend = JustAudioBackend.testing(player: player);
      addTearDown(backend.dispose);

      final events = <SpeakerPlaybackCompletedEvent>[];
      final sub = backend.playbackCompletedEvents.listen(events.add);
      addTearDown(sub.cancel);

      final playbackId = await backend.startPlayback(
        requestId: 'r1',
        audioSpec: const TtsAudioSpec.mp3(),
      );
      await backend.appendChunk(
        playbackId: playbackId,
        chunk: TtsAudioChunk(
          bytes: Uint8List.fromList([1, 2]),
          requestId: '',
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
      expect(events.single.requestId, 'r1');
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
          requestId: 'r1',
          audioSpec: const TtsAudioSpec.mp3(),
        );
        await backend.appendChunk(
          playbackId: firstPlaybackId,
          chunk: TtsAudioChunk(
            bytes: Uint8List.fromList([1, 2]),
            requestId: '',
            sequenceNumber: 0,
            isLastChunk: false,
            timestamp: DateTime.now(),
            audioSpec: const TtsAudioSpec.mp3(),
          ),
        );
        await backend.finalizePlayback(playbackId: firstPlaybackId);

        final secondPlaybackId = await backend.startPlayback(
          requestId: 'r2',
          audioSpec: const TtsAudioSpec.mp3(),
        );
        await backend.appendChunk(
          playbackId: secondPlaybackId,
          chunk: TtsAudioChunk(
            bytes: Uint8List.fromList([9, 8]),
            requestId: '',
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
          requestId: 'r1',
          audioSpec: const TtsAudioSpec.mp3(),
        );
        await backend.appendChunk(
          playbackId: firstPlaybackId,
          chunk: TtsAudioChunk(
            bytes: Uint8List.fromList([1, 2]),
            requestId: '',
            sequenceNumber: 0,
            isLastChunk: false,
            timestamp: DateTime.now(),
            audioSpec: const TtsAudioSpec.mp3(),
          ),
        );

        final secondPlaybackId = await backend.startPlayback(
          requestId: 'r2',
          audioSpec: const TtsAudioSpec.mp3(),
        );
        await backend.appendChunk(
          playbackId: secondPlaybackId,
          chunk: TtsAudioChunk(
            bytes: Uint8List.fromList([9]),
            requestId: '',
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
  });
}
