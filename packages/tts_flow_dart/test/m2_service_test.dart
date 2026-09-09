import 'dart:async';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:tts_flow_dart/tts_flow_dart.dart';

void main() {
  group('M2 service', () {
    test('processes requests in FIFO order', () async {
      final service = TtsFlow(
        engine: SineTtsEngine(
          engineId: 'fake-engine',
          supportsStreaming: true,
          chunkCount: 2,
          chunkDelay: const Duration(milliseconds: 5),
        ),
        defaultOutput: NullOutput(),
      );

      final started = <String>[];
      final sub = service.requestEvents.listen((event) {
        if (event.type == TtsRequestEventType.requestStarted) {
          started.add(event.utteranceId);
        }
      });

      await service.init();

      final streamA = service.speak('first request payload', utteranceId: 'a');
      final streamB = service.speak('second request payload', utteranceId: 'b');

      await streamA.chunks.toList();
      await streamB.chunks.toList();
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(started, ['a', 'b']);
      await sub.cancel();
      await service.dispose();
    });

    test('serializes output writes across queued requests', () async {
      final output = _LifecycleTrackingOutput(outputId: 'serial-output');
      final service = TtsFlow(
        engine: SineTtsEngine(
          engineId: 'fake-engine',
          supportsStreaming: true,
          chunkCount: 2,
          chunkDelay: const Duration(milliseconds: 2),
        ),
        defaultOutput: output,
      );

      await service.init();
      final first = service.speak('first output write');
      final second = service.speak('second output write');

      await first.chunks.toList();
      await second.chunks.toList();

      expect(output.overlappingSessionAttempted, isFalse);
      expect(output.lifecycle, [
        'init:${first.requestKey}',
        'finalize:${first.requestKey}',
        'init:${second.requestKey}',
        'finalize:${second.requestKey}',
      ]);

      await service.dispose();
    });

    test(
      'enforces engine input limits using user-perceived characters',
      () async {
        final service = TtsFlow(
          engine: _ChunkSpecEngine(
            negotiatedCapabilities: {const Mp3Capability()},
            emittedSpec: const TtsAudioSpec.mp3(),
            maxInputCharacterCount: 1,
          ),
          defaultOutput: NullOutput(),
        );
        await service.init();

        // The combining mark forms one grapheme cluster with the preceding e.
        expect(() => service.speak('e\u0301'), returnsNormally);
        expect(
          () => service.speak('ab'),
          throwsA(
            isA<TtsError>().having(
              (error) => error.code,
              'code',
              TtsErrorCode.maxInputCharacterCountExceeded,
            ),
          ),
        );

        await service.dispose();
      },
    );

    test(
      'bounded playback backlog keeps one request synthesized ahead of playback',
      () async {
        final output = _PlaybackControllableTestOutput(outputId: 'speaker');
        final service = TtsFlow(
          engine: SineTtsEngine(
            engineId: 'fake-engine',
            supportsStreaming: true,
            chunkCount: 1,
          ),
          defaultOutput: output,
          config: const TtsFlowConfig(
            synthesisAdmissionPolicy: TtsBoundedPlaybackBacklogPolicy(
              maxOutstandingPlaybackRequests: 2,
            ),
          ),
        );

        await service.init();
        final first = service.speak('first');
        final second = service.speak('second');
        final third = service.speak('third');

        await first.synthesisResult;
        await second.synthesisResult;

        expect(output.startedRequestKeys, [
          first.requestKey,
          second.requestKey,
        ]);

        output.completePlayback(first.requestKey);
        await third.synthesisResult;

        expect(output.startedRequestKeys, [
          first.requestKey,
          second.requestKey,
          third.requestKey,
        ]);

        await service.dispose();
      },
    );

    test(
      'bounded playback backlog releases a synchronous terminal write event',
      () async {
        final output = _PlaybackControllableTestOutput(
          outputId: 'speaker',
          completePlaybackWhenWriteStarts: true,
        );
        final service = TtsFlow(
          engine: SineTtsEngine(
            engineId: 'fake-engine',
            supportsStreaming: true,
            chunkCount: 1,
          ),
          defaultOutput: output,
          config: const TtsFlowConfig(
            synthesisAdmissionPolicy: TtsBoundedPlaybackBacklogPolicy(
              maxOutstandingPlaybackRequests: 1,
            ),
          ),
        );

        await service.init();
        final first = service.speak('first');
        final second = service.speak('second');

        await Future.wait([first.synthesisResult, second.synthesisResult]);

        expect(output.startedRequestKeys, [
          first.requestKey,
          second.requestKey,
        ]);
        await service.dispose();
      },
    );

    test('custom synthesis admission policy can be refreshed', () async {
      final policy = _ToggleSynthesisAdmissionPolicy(isOpen: false);
      final output = _TrackingOutput(outputId: 'output');
      final service = TtsFlow(
        engine: SineTtsEngine(
          engineId: 'fake-engine',
          supportsStreaming: true,
          chunkCount: 1,
        ),
        defaultOutput: output,
        config: TtsFlowConfig(synthesisAdmissionPolicy: policy),
      );

      await service.init();
      final request = service.speak('wait for admission');
      await Future<void>.delayed(Duration.zero);

      expect(output.consumedChunks, isEmpty);
      expect(policy.lastSnapshot?.pendingRequestCount, 1);
      expect(policy.lastSnapshot?.outstandingPlaybackRequestCount, 0);

      policy.isOpen = true;
      await service.refreshSynthesisAdmission();
      await request.synthesisResult;

      expect(output.consumedChunks, isNotEmpty);
      await service.dispose();
    });

    test('reused utterance IDs retain distinct request handles', () async {
      final service = TtsFlow(
        engine: SineTtsEngine(
          engineId: 'fake-engine',
          supportsStreaming: true,
          chunkCount: 1,
        ),
        defaultOutput: NullOutput(),
      );
      final started = <TtsRequestEvent>[];
      final subscription = service.requestEvents
          .where((event) => event.type == TtsRequestEventType.requestStarted)
          .listen(started.add);

      await service.init();
      final first = service.speak('first', utteranceId: 'shared-label');
      final second = service.speak('second', utteranceId: 'shared-label');
      final firstHandleEvents = first.events.toList();

      expect(first.requestKey, isNot(second.requestKey));
      expect(first.utteranceId, 'shared-label');
      expect(second.utteranceId, 'shared-label');
      await first.chunks.toList();
      await second.chunks.toList();
      final firstEvents = await firstHandleEvents;

      expect(started, hasLength(2));
      expect(
        started.map((event) => event.utteranceId),
        everyElement('shared-label'),
      );
      expect(started.map((event) => event.requestKey).toSet(), {
        first.requestKey,
        second.requestKey,
      });
      expect(
        firstEvents.map((event) => event.type),
        containsAll(<TtsRequestEventType>[
          TtsRequestEventType.requestQueued,
          TtsRequestEventType.requestStarted,
          TtsRequestEventType.requestSynthesisCompleted,
        ]),
      );
      expect(
        firstEvents.every(
          (event) =>
              event.requestKey == first.requestKey &&
              event.utteranceId == first.utteranceId,
        ),
        isTrue,
      );

      await subscription.cancel();
      await service.dispose();
    });

    test('request chunks have one explicit consumer', () async {
      final service = TtsFlow(
        engine: SineTtsEngine(
          engineId: 'fake-engine',
          supportsStreaming: true,
          chunkCount: 1,
        ),
        defaultOutput: NullOutput(),
      );

      await service.init();
      final handle = service.speak('single stream consumer');

      expect(handle, isNot(isA<Stream<TtsChunk>>()));
      expect(handle.chunks.isBroadcast, isFalse);
      final chunks = await handle.chunks.toList();
      expect(chunks, isNotEmpty);
      expect(() => handle.chunks.listen((_) {}), throwsA(isA<StateError>()));

      await service.dispose();
    });

    test(
      'request synthesis result exposes the finalized output artifact',
      () async {
        final output = MemoryOutput();
        final service = TtsFlow(
          engine: SineTtsEngine(
            engineId: 'fake-engine',
            supportsStreaming: true,
            chunkCount: 2,
          ),
          defaultOutput: output,
        );

        await service.init();
        final handle = service.speak(
          'artifact result',
          utteranceId: 'artifact',
        );
        await handle.chunks.toList();
        final result = await handle.synthesisResult;

        expect(result, isA<TtsSynthesisCompletedResult>());
        final completed = result as TtsSynthesisCompletedResult;
        expect(completed.requestKey, handle.requestKey);
        expect(completed.utteranceId, 'artifact');
        expect(completed.artifact, isA<InMemoryAudioArtifact>());
        expect(
          (completed.artifact as InMemoryAudioArtifact).totalBytes,
          greaterThan(0),
        );

        await service.dispose();
      },
    );

    test('clearQueue cancels pending requests only', () async {
      final service = TtsFlow(
        engine: SineTtsEngine(
          engineId: 'fake-engine',
          supportsStreaming: true,
          chunkCount: 3,
          chunkDelay: const Duration(milliseconds: 10),
        ),
        defaultOutput: NullOutput(),
      );

      await service.init();

      final active = service.speak('active request', utteranceId: 'active');
      final pending = service.speak('pending request', utteranceId: 'pending');

      await Future<void>.delayed(const Duration(milliseconds: 8));
      final clearedCount = await service.clearQueue();

      expect(clearedCount, 1);
      expect(await active.chunks.toList(), isNotEmpty);
      expect(await pending.chunks.toList(), isEmpty);
      expect(
        await pending.synthesisResult,
        isA<TtsSynthesisStoppedResult>().having(
          (result) => result.reason,
          'reason',
          TtsSynthesisStopReason.queueCleared,
        ),
      );

      await service.dispose();
    });

    test(
      'stopCurrent stops active request and next request proceeds',
      () async {
        final service = TtsFlow(
          engine: SineTtsEngine(
            engineId: 'fake-engine',
            supportsStreaming: true,
            chunkCount: 8,
            chunkDelay: const Duration(milliseconds: 5),
          ),
          defaultOutput: NullOutput(),
        );

        final events = <TtsRequestEvent>[];
        final sub = service.requestEvents.listen(events.add);

        await service.init();

        final longStream = service.speak(
          'this is a long request payload',
          utteranceId: 'long',
        );
        final nextStream = service.speak('next request', utteranceId: 'next');

        await Future<void>.delayed(const Duration(milliseconds: 12));
        await service.stopActiveSynthesis();

        await longStream.chunks.toList();
        await nextStream.chunks.toList();

        expect(
          await longStream.synthesisResult,
          isA<TtsSynthesisStoppedResult>().having(
            (result) => result.reason,
            'reason',
            TtsSynthesisStopReason.requested,
          ),
        );

        expect(
          events.any(
            (event) =>
                event.utteranceId == 'long' &&
                event.type == TtsRequestEventType.requestSynthesisStopped,
          ),
          isTrue,
        );

        final nextStartedIndex = events.indexWhere(
          (event) =>
              event.utteranceId == 'next' &&
              event.type == TtsRequestEventType.requestStarted,
        );
        expect(nextStartedIndex, isNonNegative);

        await sub.cancel();
        await service.dispose();
      },
    );

    test(
      'requestSynthesisFailed event includes output failure details',
      () async {
        final service = TtsFlow(
          engine: SineTtsEngine(
            engineId: 'fake-engine',
            supportsStreaming: true,
            chunkCount: 2,
            chunkDelay: const Duration(milliseconds: 2),
          ),
          defaultOutput: MulticastOutput(
            outputs: [
              MemoryOutput(outputId: 'memory'),
              _AlwaysFailOutput(outputId: 'fail-output'),
            ],
            errorPolicy: MulticastOutputErrorPolicy.failFast,
          ),
        );

        TtsRequestEvent? failedEvent;
        final sub = service.requestEvents.listen((event) {
          if (event.type == TtsRequestEventType.requestSynthesisFailed) {
            failedEvent = event;
          }
        });

        await service.init();

        final stream = service.speak(
          'fail through output',
          utteranceId: 'output-fail',
        );

        await expectLater(stream.chunks.toList(), throwsA(isA<TtsError>()));
        expect(
          await stream.synthesisResult,
          isA<TtsSynthesisFailedResult>().having(
            (result) => result.error.code,
            'error code',
            TtsErrorCode.outputWriteFailed,
          ),
        );
        await Future<void>.delayed(const Duration(milliseconds: 20));

        expect(failedEvent, isNotNull);
        expect(failedEvent!.outputId, 'fail-output');
        expect(failedEvent!.outputError, isNotNull);
        expect(failedEvent!.outputError!.code, TtsErrorCode.outputWriteFailed);

        await sub.cancel();
        await service.dispose();
      },
    );

    test('starts output writing using first chunk audioSpec', () async {
      final output = _TrackingOutput(outputId: 'tracking-output');
      final service = TtsFlow(
        engine: _ChunkSpecEngine(
          negotiatedCapabilities: {PcmCapability.wav(), const Mp3Capability()},
          emittedSpec: const TtsAudioSpec.mp3(),
        ),
        defaultOutput: output,
      );

      await service.init();
      service.preferredFormat = TtsAudioFormat.pcm;

      final chunks = await service
          .speak('hello', utteranceId: 'chunk-spec-init')
          .chunks
          .toList();

      expect(chunks, hasLength(1));
      expect(chunks.single, isA<TtsAudioChunk>());
      expect(
        (chunks.single as TtsAudioChunk).audioSpec.format,
        TtsAudioFormat.mp3,
      );
      expect(output.lastInitAudioSpec, isNotNull);
      expect(output.lastInitAudioSpec!.format, TtsAudioFormat.mp3);

      await service.dispose();
    });

    test(
      'fails during negotiation when multicast children have disjoint PCM',
      () async {
        final service = TtsFlow(
          engine: SineTtsEngine(
            engineId: 'fake-engine',
            supportsStreaming: true,
            chunkCount: 2,
            chunkDelay: const Duration(milliseconds: 2),
          ),
          defaultOutput: MulticastOutput(
            outputs: [
              _PcmOnlyOutput(outputId: 'pcm-16k', sampleRatesHz: {16000}),
              _PcmOnlyOutput(outputId: 'pcm-24k', sampleRatesHz: {24000}),
            ],
            errorPolicy: MulticastOutputErrorPolicy.failFast,
          ),
        );

        await service.init();

        final stream = service.speak(
          'disjoint constraints',
          utteranceId: 'pcm-disjoint',
        );

        await expectLater(
          stream.chunks.toList(),
          throwsA(
            isA<TtsError>().having(
              (error) => error.code,
              'code',
              TtsErrorCode.formatNegotiationFailed,
            ),
          ),
        );

        await service.dispose();
      },
    );

    test('continueOnError keeps pending queue after active failure', () async {
      final service = TtsFlow(
        engine: SineTtsEngine(
          engineId: 'fake-engine',
          supportsStreaming: true,
          chunkCount: 2,
          chunkDelay: const Duration(milliseconds: 2),
        ),
        defaultOutput: _FailFirstOutput(
          outputId: 'selective-fail',
          remainingFailures: 1,
        ),
        config: const TtsFlowConfig(
          queueFailurePolicy: TtsQueueFailurePolicy.continueOnError,
        ),
      );

      final events = <TtsRequestEvent>[];
      final sub = service.requestEvents.listen(events.add);

      await service.init();

      final first = service.speak('this will fail', utteranceId: 'first');
      final second = service.speak(
        'this should still run',
        utteranceId: 'second',
      );

      await expectLater(first.chunks.toList(), throwsA(isA<TtsError>()));
      final secondChunks = await second.chunks.toList();

      expect(secondChunks, isNotEmpty);
      expect(
        events.any(
          (event) =>
              event.utteranceId == 'second' &&
              event.type == TtsRequestEventType.requestSynthesisCompleted,
        ),
        isTrue,
      );

      await sub.cancel();
      await service.dispose();
    });

    test('pause while idle defers start until resume', () async {
      final service = TtsFlow(
        engine: SineTtsEngine(
          engineId: 'fake-engine',
          supportsStreaming: true,
          chunkCount: 2,
          chunkDelay: const Duration(milliseconds: 5),
        ),
        defaultOutput: NullOutput(),
      );

      final started = <String>[];
      final sub = service.requestEvents.listen((event) {
        if (event.type == TtsRequestEventType.requestStarted) {
          started.add(event.utteranceId);
        }
      });

      await service.init();

      await service.pauseQueue();
      expect(service.isQueuePaused, isTrue);

      final first = service.speak('first queued', utteranceId: 'paused-1');
      final second = service.speak('second queued', utteranceId: 'paused-2');

      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(started, isEmpty);

      await service.resumeQueue();
      expect(service.isQueuePaused, isFalse);

      await first.chunks.toList();
      await second.chunks.toList();

      expect(started, ['paused-1', 'paused-2']);

      await sub.cancel();
      await service.dispose();
    });

    test('pausing the queue does not delay active synthesis output', () async {
      final service = TtsFlow(
        engine: SineTtsEngine(
          engineId: 'fake-engine',
          supportsStreaming: true,
          chunkCount: 4,
          chunkDelay: const Duration(milliseconds: 5),
        ),
        defaultOutput: NullOutput(),
      );
      final started = <String>[];
      final subscription = service.requestEvents
          .where((event) => event.type == TtsRequestEventType.requestStarted)
          .listen((event) => started.add(event.utteranceId));

      await service.init();
      final active = service.speak('active request', utteranceId: 'active');
      final pending = service.speak('pending request', utteranceId: 'pending');

      await Future<void>.delayed(const Duration(milliseconds: 8));
      await service.pauseQueue();

      expect(
        await active.chunks.toList().timeout(const Duration(milliseconds: 200)),
        isNotEmpty,
      );
      expect(started, ['active']);

      await service.resumeQueue();
      expect(await pending.chunks.toList(), isNotEmpty);

      await subscription.cancel();
      await service.dispose();
    });

    test('stopCurrent forwards stopCurrent cancel reason to output', () async {
      final output = _CaptureCancelOutput();
      final service = TtsFlow(
        engine: SineTtsEngine(
          engineId: 'fake-engine',
          supportsStreaming: true,
          chunkCount: 8,
          chunkDelay: const Duration(milliseconds: 5),
        ),
        defaultOutput: output,
      );

      await service.init();

      final longStream = service.speak(
        'long request',
        utteranceId: 'cancel-reason',
      );

      await Future<void>.delayed(const Duration(milliseconds: 12));
      await service.stopActiveSynthesis();
      await longStream.chunks.toList();

      expect(output.lastCancelReason, CancelReason.stopCurrent);
      await service.dispose();
    });

    test(
      'dispose during paused active request forwards serviceDispose reason',
      () async {
        final output = _CaptureCancelOutput();
        final service = TtsFlow(
          engine: SineTtsEngine(
            engineId: 'fake-engine',
            supportsStreaming: true,
            chunkCount: 20,
            chunkDelay: const Duration(milliseconds: 5),
          ),
          defaultOutput: output,
        );

        await service.init();

        final stream = service.speak(
          'this request should be canceled by service dispose while paused',
          utteranceId: 'dispose-paused',
        );

        await Future<void>.delayed(const Duration(milliseconds: 12));
        await service.pauseQueue();
        await Future<void>.delayed(const Duration(milliseconds: 12));
        await service.dispose();

        final chunks = await stream.chunks.toList();
        expect(chunks, isNotNull);
        expect(output.lastCancelReason, CancelReason.serviceDispose);
      },
    );

    test('service exposes engine available voices and defaults', () async {
      final service = TtsFlow(
        engine: SineTtsEngine(engineId: 'fake-engine', supportsStreaming: true),
        defaultOutput: NullOutput(),
      );

      await service.init();

      final voices = await service.getAvailableVoices();
      final defaultVoice = await service.getDefaultVoice();
      final localeDefault = await service.getDefaultVoiceForLocale('en-US');

      expect(voices, isNotEmpty);
      expect(defaultVoice.voiceId, isNotEmpty);
      expect(localeDefault.voiceId, isNotEmpty);
      expect(service.voice, isNotNull);

      service.speed = 1.1;
      service.pitch = 0.9;
      service.volume = 0.8;
      service.sampleRateHz = 24000;
      service.preferredFormat = TtsAudioFormat.pcm;
      expect(service.speed, 1.1);
      expect(service.pitch, 0.9);
      expect(service.volume, 0.8);
      expect(service.sampleRateHz, 24000);

      final streamedChunks = await service
          .speak(
            'request uses service defaults',
            utteranceId: 'defaults-applied',
            params: const {'style': 'news', 'emotion': 'calm'},
          )
          .chunks
          .toList();
      expect(streamedChunks, isNotEmpty);

      await service.dispose();
    });

    test('speak requires init before usage', () async {
      final service = TtsFlow(
        engine: SineTtsEngine(engineId: 'fake-engine', supportsStreaming: true),
        defaultOutput: NullOutput(),
      );

      expect(
        () => service.speak('call before init', utteranceId: 'not-ready'),
        throwsStateError,
      );

      await service.dispose();
    });

    test(
      'requestSynthesisCompleted is write-based and playback completion is separate',
      () async {
        final output = _PlaybackAwareTestOutput(
          outputId: 'playback-aware',
          playbackCompletionDelay: const Duration(milliseconds: 30),
        );
        final service = TtsFlow(
          engine: SineTtsEngine(
            engineId: 'fake-engine',
            supportsStreaming: true,
            chunkCount: 2,
            chunkDelay: const Duration(milliseconds: 2),
          ),
          defaultOutput: output,
        );

        final events = <TtsRequestEvent>[];
        final sub = service.requestEvents.listen(events.add);

        await service.init();
        final request = service.speak('hello', utteranceId: 'playback-split');
        await request.chunks.toList();

        await Future<void>.delayed(const Duration(milliseconds: 60));

        final completedIndex = events.indexWhere(
          (event) =>
              event.utteranceId == 'playback-split' &&
              event.type == TtsRequestEventType.requestSynthesisCompleted,
        );
        final playbackCompletedIndex = events.indexWhere(
          (event) =>
              event.utteranceId == 'playback-split' &&
              event.type == TtsRequestEventType.requestPlaybackCompleted,
        );

        expect(completedIndex, isNonNegative);
        expect(playbackCompletedIndex, greaterThan(completedIndex));

        final playbackEvent =
            events[playbackCompletedIndex.clamp(0, events.length - 1)];
        expect(playbackEvent.outputId, 'playback-aware');
        expect(playbackEvent.playbackId, 'playback-${request.requestKey}');
        expect(playbackEvent.playedDuration, isNotNull);
        expect(playbackEvent.playedDuration!, greaterThan(Duration.zero));

        await sub.cancel();
        await service.dispose();
      },
    );

    test(
      'requestPlaybackFailed is separate from completed synthesis',
      () async {
        final output = _PlaybackAwareTestOutput(
          outputId: 'playback-aware',
          playbackCompletionDelay: null,
          playbackFailureDelay: const Duration(milliseconds: 30),
        );
        final service = TtsFlow(
          engine: SineTtsEngine(
            engineId: 'fake-engine',
            supportsStreaming: true,
            chunkCount: 2,
            chunkDelay: const Duration(milliseconds: 2),
          ),
          defaultOutput: output,
        );

        final events = <TtsRequestEvent>[];
        final sub = service.requestEvents.listen(events.add);

        await service.init();
        final request = service.speak('hello', utteranceId: 'playback-failed');
        await request.chunks.toList();
        await Future<void>.delayed(const Duration(milliseconds: 60));

        final completedIndex = events.indexWhere(
          (event) =>
              event.utteranceId == 'playback-failed' &&
              event.type == TtsRequestEventType.requestSynthesisCompleted,
        );
        final playbackFailedIndex = events.indexWhere(
          (event) =>
              event.utteranceId == 'playback-failed' &&
              event.type == TtsRequestEventType.requestPlaybackFailed,
        );

        expect(completedIndex, isNonNegative);
        expect(playbackFailedIndex, greaterThan(completedIndex));
        final playbackEvent =
            events[playbackFailedIndex.clamp(0, events.length - 1)];
        expect(playbackEvent.state, isNull);
        expect(playbackEvent.outputId, 'playback-aware');
        expect(playbackEvent.playbackId, 'playback-${request.requestKey}');
        expect(playbackEvent.error?.code, TtsErrorCode.outputPlaybackFailed);

        await sub.cancel();
        await service.dispose();
      },
    );

    test(
      'physical playback controls are separate from synthesis controls',
      () async {
        final output = _PlaybackControllableTestOutput(outputId: 'speaker');
        final service = TtsFlow(
          engine: SineTtsEngine(
            engineId: 'fake-engine',
            supportsStreaming: true,
            chunkCount: 1,
          ),
          defaultOutput: output,
        );
        final events = <TtsRequestEvent>[];
        final sub = service.requestEvents.listen(events.add);

        await service.init();
        final request = service.speak('hello', utteranceId: 'playback-control');
        await request.chunks.drain();

        expect(request.hasActivePlayback, isTrue);
        await request.pausePlayback();
        await request.resumePlayback();
        await request.stopPlayback();
        await Future<void>.delayed(Duration.zero);

        expect(output.pauseCount, 1);
        expect(output.resumeCount, 1);
        expect(output.stopCount, 1);
        expect(request.hasActivePlayback, isFalse);
        expect(
          events.map((event) => event.type),
          containsAll(<TtsRequestEventType>[
            TtsRequestEventType.requestPlaybackPaused,
            TtsRequestEventType.requestPlaybackResumed,
            TtsRequestEventType.requestPlaybackStopped,
          ]),
        );

        await sub.cancel();
        await service.dispose();
      },
    );

    test(
      'speak with output override routes audio only to override output',
      () async {
        final defaultOutput = _TrackingOutput(outputId: 'default');
        final overrideOutput = _TrackingOutput(outputId: 'override');
        final service = TtsFlow(
          engine: SineTtsEngine(
            engineId: 'fake-engine',
            supportsStreaming: true,
            chunkCount: 3,
            chunkDelay: const Duration(milliseconds: 2),
          ),
          defaultOutput: defaultOutput,
        );

        await service.init();

        final chunks = await service
            .speak(
              'override output test',
              utteranceId: 'override-1',
              output: overrideOutput,
            )
            .chunks
            .toList();

        expect(chunks, isNotEmpty);
        expect(overrideOutput.consumedChunks, isNotEmpty);
        expect(defaultOutput.consumedChunks, isEmpty);

        await service.dispose();
      },
    );

    test('flow initializes and disposes request-level outputs', () async {
      final defaultOutput = _LifecycleTrackingOutput(outputId: 'default');
      final overrideOutput = _LifecycleTrackingOutput(outputId: 'override');
      final service = TtsFlow(
        engine: SineTtsEngine(
          engineId: 'fake-engine',
          supportsStreaming: true,
          chunkCount: 1,
        ),
        defaultOutput: defaultOutput,
      );

      await service.init();
      expect(defaultOutput.initCount, 1);
      expect(overrideOutput.initCount, 0);

      await service
          .speak(
            'hello',
            utteranceId: 'override-lifecycle',
            output: overrideOutput,
          )
          .chunks
          .drain();

      expect(overrideOutput.initCount, 1);
      expect(overrideOutput.startWriteCount, 1);
      expect(defaultOutput.startWriteCount, 0);

      await service.dispose();

      expect(defaultOutput.disposeCount, 1);
      expect(overrideOutput.disposeCount, 1);
    });

    test('flow initializes a reused output only once', () async {
      final output = _LifecycleTrackingOutput(outputId: 'reused');
      final service = TtsFlow(
        engine: SineTtsEngine(
          engineId: 'fake-engine',
          supportsStreaming: true,
          chunkCount: 1,
        ),
      );

      await service.init();
      await service
          .speak('first', utteranceId: 'reused-1', output: output)
          .chunks
          .drain();
      await service
          .speak('second', utteranceId: 'reused-2', output: output)
          .chunks
          .drain();

      expect(output.initCount, 1);
      expect(output.startWriteCount, 2);

      await service.dispose();
      expect(output.disposeCount, 1);
    });

    test(
      'request-level output initialization failure follows queue policy',
      () async {
        final failingOutput = _LifecycleTrackingOutput(
          outputId: 'failing',
          throwOnInit: true,
        );
        final succeedingOutput = _LifecycleTrackingOutput(
          outputId: 'succeeding',
        );
        final service = TtsFlow(
          engine: SineTtsEngine(
            engineId: 'fake-engine',
            supportsStreaming: true,
            chunkCount: 1,
          ),
          config: const TtsFlowConfig(
            queueFailurePolicy: TtsQueueFailurePolicy.continueOnError,
          ),
        );

        await service.init();

        await expectLater(
          service
              .speak('first', utteranceId: 'init-fails', output: failingOutput)
              .chunks
              .drain(),
          throwsA(isA<TtsError>()),
        );
        await service
            .speak(
              'second',
              utteranceId: 'init-succeeds',
              output: succeedingOutput,
            )
            .chunks
            .drain();

        expect(failingOutput.initCount, 1);
        expect(succeedingOutput.startWriteCount, 1);

        await service.dispose();
        expect(failingOutput.disposeCount, 1);
        expect(succeedingOutput.disposeCount, 1);
      },
    );

    test('no default output and no override fails request', () async {
      final service = TtsFlow(
        engine: SineTtsEngine(
          engineId: 'fake-engine',
          supportsStreaming: true,
          chunkCount: 2,
          chunkDelay: const Duration(milliseconds: 2),
        ),
      );

      await service.init();

      expect(
        () => service.speak('missing output', utteranceId: 'no-output'),
        throwsA(
          isA<TtsError>()
              .having(
                (error) => error.code,
                'code',
                TtsErrorCode.invalidRequest,
              )
              .having((error) => error.requestKey, 'requestKey', isNotEmpty),
        ),
      );

      await service.dispose();
    });

    test(
      'no default output with per-request override works normally',
      () async {
        final overrideOutput = _TrackingOutput(outputId: 'override');
        final service = TtsFlow(
          engine: SineTtsEngine(
            engineId: 'fake-engine',
            supportsStreaming: true,
            chunkCount: 3,
            chunkDelay: const Duration(milliseconds: 2),
          ),
        );

        await service.init();

        final chunks = await service
            .speak(
              'no default, use override',
              utteranceId: 'no-default-override',
              output: overrideOutput,
            )
            .chunks
            .toList();

        expect(chunks, isNotEmpty);
        expect(overrideOutput.consumedChunks, isNotEmpty);

        await service.dispose();
      },
    );
  });
}

final class _AlwaysFailOutput implements TtsOutput {
  _AlwaysFailOutput({required this.outputId});

  @override
  final String outputId;

  @override
  Set<AudioCapability> get inAudioCapabilities => {PcmCapability.wav()};

  @override
  Future<void> init() async {}

  @override
  Future<void> startWrite(TtsOutputWriteContext session) async {}

  @override
  Future<void> writeChunk(TtsChunk chunk) async {
    throw const TtsError(
      code: TtsErrorCode.outputWriteFailed,
      message: 'Injected output failure.',
    );
  }

  @override
  Future<AudioArtifact> finishWrite() async {
    throw const TtsError(
      code: TtsErrorCode.outputWriteFailed,
      message: 'Injected output failure.',
    );
  }

  @override
  Future<void> cancelWrite(SynthesisControl control) async {}

  @override
  Future<void> dispose() async {}
}

final class _FailFirstOutput implements TtsOutput {
  _FailFirstOutput({required this.outputId, required int remainingFailures})
    : _remainingFailures = remainingFailures;

  @override
  final String outputId;

  int _remainingFailures;
  TtsOutputWriteContext? _session;

  @override
  Set<AudioCapability> get inAudioCapabilities => {PcmCapability.wav()};

  @override
  Future<void> init() async {}

  @override
  Future<void> startWrite(TtsOutputWriteContext session) async {
    _session = session;
  }

  @override
  Future<void> writeChunk(TtsChunk chunk) async {
    final session = _session;
    if (session == null) {
      return;
    }
    if (_remainingFailures > 0) {
      _remainingFailures--;
      throw const TtsError(
        code: TtsErrorCode.outputWriteFailed,
        message: 'Injected request-specific failure.',
      );
    }
  }

  @override
  Future<AudioArtifact> finishWrite() async {
    final session = _session;
    if (session == null) {
      throw StateError('No active output session.');
    }
    return InMemoryAudioArtifact(
      requestKey: session.requestKey,
      audioSpec: session.audioSpec,
      audioBytes: Uint8List(0),
      totalBytes: 0,
    );
  }

  @override
  Future<void> cancelWrite(SynthesisControl control) async {}

  @override
  Future<void> dispose() async {
    _session = null;
  }
}

final class _CaptureCancelOutput implements TtsOutput {
  final BytesBuilder _buffer = BytesBuilder(copy: false);
  TtsOutputWriteContext? _session;
  CancelReason? lastCancelReason;

  @override
  String get outputId => 'capture-cancel-output';

  @override
  Set<AudioCapability> get inAudioCapabilities => {
    PcmCapability.wav(),
    const Mp3Capability(),
  };

  @override
  Future<void> init() async {}

  @override
  Future<void> startWrite(TtsOutputWriteContext session) async {
    _session = session;
    _buffer.clear();
  }

  @override
  Future<void> writeChunk(TtsChunk chunk) async {
    if (chunk is! TtsAudioChunk) {
      return;
    }

    _buffer.add(chunk.bytes);
  }

  @override
  Future<AudioArtifact> finishWrite() async {
    final session = _session;
    if (session == null) {
      throw StateError('No active output session.');
    }
    final bytes = _buffer.takeBytes();
    _session = null;
    return InMemoryAudioArtifact(
      requestKey: session.requestKey,
      audioSpec: session.audioSpec,
      audioBytes: bytes,
      totalBytes: bytes.length,
    );
  }

  @override
  Future<void> cancelWrite(SynthesisControl control) async {
    lastCancelReason = control.cancelReason;
    _session = null;
    _buffer.clear();
  }

  @override
  Future<void> dispose() async {
    _session = null;
    _buffer.clear();
  }
}

final class _PcmOnlyOutput implements TtsOutput {
  _PcmOnlyOutput({required this.outputId, required Set<int> sampleRatesHz})
    : _sampleRatesHz = Set<int>.from(sampleRatesHz);

  @override
  final String outputId;

  final Set<int> _sampleRatesHz;
  TtsOutputWriteContext? _session;

  @override
  Set<AudioCapability> get inAudioCapabilities => {
    PcmCapability(
      sampleRatesHz: _sampleRatesHz,
      bitsPerSample: const {16},
      channels: const {1},
      encodings: const {PcmEncoding.signedInt},
    ),
  };

  @override
  Future<void> init() async {}

  @override
  Future<void> startWrite(TtsOutputWriteContext session) async {
    _session = session;
  }

  @override
  Future<void> writeChunk(TtsChunk chunk) async {}

  @override
  Future<AudioArtifact> finishWrite() async {
    final session = _session;
    if (session == null) {
      throw StateError('No active output session.');
    }
    return InMemoryAudioArtifact(
      requestKey: session.requestKey,
      audioSpec: session.audioSpec,
      audioBytes: Uint8List(0),
      totalBytes: 0,
    );
  }

  @override
  Future<void> cancelWrite(SynthesisControl control) async {
    _session = null;
  }

  @override
  Future<void> dispose() async {
    _session = null;
  }
}

final class _TrackingOutput implements TtsOutput {
  _TrackingOutput({required this.outputId});

  @override
  final String outputId;

  final List<TtsChunk> consumedChunks = [];
  TtsOutputWriteContext? _session;
  TtsAudioSpec? lastInitAudioSpec;

  @override
  Set<AudioCapability> get inAudioCapabilities => {
    PcmCapability.wav(),
    const Mp3Capability(),
  };

  @override
  Future<void> init() async {}

  @override
  Future<void> startWrite(TtsOutputWriteContext session) async {
    _session = session;
    lastInitAudioSpec = session.audioSpec;
    consumedChunks.clear();
  }

  @override
  Future<void> writeChunk(TtsChunk chunk) async {
    consumedChunks.add(chunk);
  }

  @override
  Future<AudioArtifact> finishWrite() async {
    final session = _session;
    if (session == null) throw StateError('No active session.');
    return InMemoryAudioArtifact(
      requestKey: session.requestKey,
      audioSpec: session.audioSpec,
      audioBytes: Uint8List(0),
      totalBytes: 0,
    );
  }

  @override
  Future<void> cancelWrite(SynthesisControl control) async {
    _session = null;
  }

  @override
  Future<void> dispose() async {
    _session = null;
    lastInitAudioSpec = null;
  }
}

final class _LifecycleTrackingOutput implements TtsOutput {
  _LifecycleTrackingOutput({required this.outputId, this.throwOnInit = false});

  @override
  final String outputId;

  final bool throwOnInit;

  var initCount = 0;
  var startWriteCount = 0;
  var disposeCount = 0;
  var overlappingSessionAttempted = false;
  final lifecycle = <String>[];
  var _initialized = false;
  TtsOutputWriteContext? _session;

  @override
  Set<AudioCapability> get inAudioCapabilities => {PcmCapability.wav()};

  @override
  Future<void> init() async {
    initCount++;
    if (throwOnInit) {
      throw StateError('Injected initialization failure.');
    }
    _initialized = true;
  }

  @override
  Future<void> startWrite(TtsOutputWriteContext session) async {
    if (!_initialized) {
      throw StateError('Output was not initialized.');
    }
    if (_session != null) {
      overlappingSessionAttempted = true;
      throw StateError('Previous output session is still active.');
    }
    startWriteCount++;
    _session = session;
    lifecycle.add('init:${session.requestKey}');
  }

  @override
  Future<void> writeChunk(TtsChunk chunk) async {}

  @override
  Future<AudioArtifact> finishWrite() async {
    final session = _session;
    if (session == null) {
      throw StateError('No active output session.');
    }
    _session = null;
    lifecycle.add('finalize:${session.requestKey}');
    return InMemoryAudioArtifact(
      requestKey: session.requestKey,
      audioSpec: session.audioSpec,
      audioBytes: Uint8List(0),
      totalBytes: 0,
    );
  }

  @override
  Future<void> cancelWrite(SynthesisControl control) async {
    final requestKey = _session?.requestKey;
    _session = null;
    if (requestKey != null) {
      lifecycle.add('cancel:$requestKey');
    }
  }

  @override
  Future<void> dispose() async {
    disposeCount++;
    _session = null;
  }
}

final class _ChunkSpecEngine with TtsEngineDefaults implements TtsEngine {
  _ChunkSpecEngine({
    required Set<AudioCapability> negotiatedCapabilities,
    required this.emittedSpec,
    this.maxInputCharacterCount = 0,
  }) : _negotiatedCapabilities = Set<AudioCapability>.from(
         negotiatedCapabilities,
       );

  final Set<AudioCapability> _negotiatedCapabilities;
  final TtsAudioSpec emittedSpec;

  @override
  String get engineId => 'chunk-spec-engine';

  @override
  final int maxInputCharacterCount;

  @override
  bool get supportsStreaming => true;

  @override
  Set<AudioCapability> get outAudioCapabilities => _negotiatedCapabilities;

  @override
  Future<List<TtsVoice>> getAvailableVoices({String? locale}) async {
    return const [TtsVoice(voiceId: 'default', isDefault: true)];
  }

  @override
  Future<TtsVoice> getDefaultVoice() async {
    return const TtsVoice(voiceId: 'default', isDefault: true);
  }

  @override
  Future<TtsVoice> getDefaultVoiceForLocale(String locale) async {
    return const TtsVoice(voiceId: 'default', isDefault: true);
  }

  @override
  Future<void> init() async {}

  @override
  Stream<TtsChunk> synthesize(
    TtsRequest request,
    SynthesisControl control,
    TtsAudioSpec resolvedFormat,
  ) async* {
    yield TtsAudioChunk(
      requestKey: request.requestKey,
      sequenceNumber: 0,
      bytes: Uint8List.fromList(<int>[1, 2, 3]),
      audioSpec: emittedSpec,
      isLastChunk: true,
      timestamp: DateTime.now().toUtc(),
    );
  }

  @override
  Future<void> dispose() async {}
}

final class _PlaybackAwareTestOutput
    implements TtsOutput, PlaybackAwareOutput, PlaybackFailureAwareOutput {
  _PlaybackAwareTestOutput({
    required this.outputId,
    required this.playbackCompletionDelay,
    this.playbackFailureDelay,
  });

  @override
  final String outputId;

  final Duration? playbackCompletionDelay;
  final Duration? playbackFailureDelay;
  final StreamController<TtsOutputPlaybackCompletedEvent>
  _playbackCompletedController =
      StreamController<TtsOutputPlaybackCompletedEvent>.broadcast();
  final StreamController<TtsOutputPlaybackFailedEvent>
  _playbackFailedController =
      StreamController<TtsOutputPlaybackFailedEvent>.broadcast();

  TtsOutputWriteContext? _session;
  String? _playbackId;
  int _bytesCount = 0;

  @override
  Set<AudioCapability> get inAudioCapabilities => {
    PcmCapability.wav(),
    const Mp3Capability(),
  };

  @override
  Stream<TtsOutputPlaybackCompletedEvent> get playbackCompletedEvents =>
      _playbackCompletedController.stream;

  @override
  Stream<TtsOutputPlaybackFailedEvent> get playbackFailedEvents =>
      _playbackFailedController.stream;

  @override
  Future<void> init() async {}

  @override
  Future<void> startWrite(TtsOutputWriteContext session) async {
    _session = session;
    _playbackId = 'playback-${session.requestKey}';
    _bytesCount = 0;
  }

  @override
  Future<void> writeChunk(TtsChunk chunk) async {
    if (chunk is! TtsAudioChunk) {
      return;
    }
    _bytesCount += chunk.bytes.length;
  }

  @override
  Future<AudioArtifact> finishWrite() async {
    final session = _session;
    final playbackId = _playbackId;
    if (session == null || playbackId == null) {
      throw StateError('No active session.');
    }

    final completionDelay = playbackCompletionDelay;
    if (completionDelay != null) {
      Future<void>.delayed(completionDelay, () {
        if (_playbackCompletedController.isClosed) {
          return;
        }
        _playbackCompletedController.add(
          TtsOutputPlaybackCompletedEvent(
            requestKey: session.requestKey,
            outputId: outputId,
            playbackId: playbackId,
            playedDuration: Duration(milliseconds: _bytesCount),
          ),
        );
      });
    }
    final failureDelay = playbackFailureDelay;
    if (failureDelay != null) {
      Future<void>.delayed(failureDelay, () {
        if (_playbackFailedController.isClosed) {
          return;
        }
        _playbackFailedController.add(
          TtsOutputPlaybackFailedEvent(
            requestKey: session.requestKey,
            outputId: outputId,
            playbackId: playbackId,
            error: TtsError(
              code: TtsErrorCode.outputPlaybackFailed,
              message: 'Playback failed in test output.',
              requestKey: session.requestKey,
            ),
          ),
        );
      });
    }

    _session = null;
    _playbackId = null;
    return PlaybackAudioArtifact(
      requestKey: session.requestKey,
      audioSpec: session.audioSpec,
      playbackId: playbackId,
    );
  }

  @override
  Future<void> cancelWrite(SynthesisControl control) async {
    _session = null;
    _playbackId = null;
  }

  @override
  Future<void> dispose() async {
    _session = null;
    _playbackId = null;
    await _playbackCompletedController.close();
    await _playbackFailedController.close();
  }
}

final class _PlaybackControllableTestOutput
    implements TtsOutput, PlaybackControllableOutput {
  _PlaybackControllableTestOutput({
    required this.outputId,
    this.completePlaybackWhenWriteStarts = false,
  }) : _completed = StreamController<TtsOutputPlaybackCompletedEvent>.broadcast(
         sync: completePlaybackWhenWriteStarts,
       ),
       _failed = StreamController<TtsOutputPlaybackFailedEvent>.broadcast(
         sync: completePlaybackWhenWriteStarts,
       );

  @override
  final String outputId;

  final bool completePlaybackWhenWriteStarts;

  final StreamController<TtsOutputPlaybackCompletedEvent> _completed;
  final StreamController<TtsOutputPlaybackFailedEvent> _failed;
  final Set<String> _activeRequestKeys = <String>{};
  final List<String> startedRequestKeys = <String>[];
  TtsOutputWriteContext? _session;
  var pauseCount = 0;
  var resumeCount = 0;
  var stopCount = 0;

  @override
  Set<AudioCapability> get inAudioCapabilities => {PcmCapability.wav()};

  @override
  Stream<TtsOutputPlaybackCompletedEvent> get playbackCompletedEvents =>
      _completed.stream;

  @override
  Stream<TtsOutputPlaybackFailedEvent> get playbackFailedEvents =>
      _failed.stream;

  @override
  Future<void> init() async {}

  @override
  Future<void> startWrite(TtsOutputWriteContext session) async {
    _session = session;
    _activeRequestKeys.add(session.requestKey);
    startedRequestKeys.add(session.requestKey);
    if (completePlaybackWhenWriteStarts) {
      completePlayback(session.requestKey);
    }
  }

  @override
  Future<void> writeChunk(TtsChunk chunk) async {}

  @override
  Future<AudioArtifact> finishWrite() async {
    final session = _session;
    if (session == null) {
      throw StateError('No active output session.');
    }
    _session = null;
    return PlaybackAudioArtifact(
      requestKey: session.requestKey,
      audioSpec: session.audioSpec,
      playbackId: 'playback-${session.requestKey}',
    );
  }

  @override
  Future<void> cancelWrite(SynthesisControl control) async {
    final requestKey = _session?.requestKey;
    if (requestKey != null) {
      _activeRequestKeys.remove(requestKey);
    }
    _session = null;
  }

  @override
  bool hasActivePlayback(String requestKey) =>
      _activeRequestKeys.contains(requestKey);

  @override
  Future<void> pausePlayback(String requestKey) async {
    if (!hasActivePlayback(requestKey)) {
      throw StateError('No active playback.');
    }
    pauseCount++;
  }

  @override
  Future<void> resumePlayback(String requestKey) async {
    if (!hasActivePlayback(requestKey)) {
      throw StateError('No active playback.');
    }
    resumeCount++;
  }

  @override
  Future<void> stopPlayback(String requestKey) async {
    if (!hasActivePlayback(requestKey)) {
      throw StateError('No active playback.');
    }
    stopCount++;
    _activeRequestKeys.remove(requestKey);
  }

  void completePlayback(String requestKey) {
    if (!_activeRequestKeys.remove(requestKey)) {
      throw StateError('No active playback.');
    }
    _completed.add(
      TtsOutputPlaybackCompletedEvent(
        requestKey: requestKey,
        outputId: outputId,
        playbackId: 'playback-$requestKey',
      ),
    );
  }

  @override
  Future<void> dispose() async {
    _activeRequestKeys.clear();
    await _completed.close();
    await _failed.close();
  }
}

final class _ToggleSynthesisAdmissionPolicy
    implements TtsSynthesisAdmissionPolicy {
  _ToggleSynthesisAdmissionPolicy({required this.isOpen});

  bool isOpen;
  TtsSynthesisAdmissionSnapshot? lastSnapshot;

  @override
  bool allowsNextSynthesis(TtsSynthesisAdmissionSnapshot snapshot) {
    lastSnapshot = snapshot;
    return isOpen;
  }
}
