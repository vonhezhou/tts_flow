import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:tts_flow_dart/tts_flow_dart.dart';

/// Minimal reference backend that demonstrates the expected lifecycle contract
/// for [SpeakerBackend].
final class _ReferenceSpeakerBackend implements SpeakerBackend {
  final Map<String, List<int>> _buffers = <String, List<int>>{};
  final Set<String> _closed = <String>{};

  @override
  Stream<SpeakerPlaybackCompletedEvent> get playbackCompletedEvents =>
      const Stream<SpeakerPlaybackCompletedEvent>.empty();

  @override
  Set<AudioCapability> get supportedCapabilities => {const Mp3Capability()};

  @override
  Future<void> init() async {}

  @override
  Future<String> startPlayback({
    required String requestId,
    required TtsAudioSpec audioSpec,
  }) async {
    final playbackId = 'ref-$requestId';
    _buffers[playbackId] = <int>[];
    _closed.remove(playbackId);
    return playbackId;
  }

  @override
  Future<void> appendChunk({
    required String playbackId,
    required TtsChunk chunk,
  }) async {
    if (_closed.contains(playbackId)) {
      throw StateError('Playback already closed: $playbackId');
    }
    final buffer = _buffers[playbackId];
    if (buffer == null) {
      throw StateError('Unknown playbackId: $playbackId');
    }
    if (chunk is! TtsAudioChunk) {
      return;
    }

    buffer.addAll(chunk.bytes);
  }

  @override
  Future<void> finalizePlayback({required String playbackId}) async {
    final buffer = _buffers.remove(playbackId);
    if (buffer == null) {
      throw StateError('Unknown playbackId: $playbackId');
    }
    _closed.add(playbackId);
  }

  @override
  Future<void> stopPlayback({
    required String playbackId,
    String? reason,
  }) async {
    _buffers.remove(playbackId);
    _closed.add(playbackId);
  }

  @override
  Future<void> pausePlayback({required String playbackId}) async {}

  @override
  Future<void> resumePlayback({required String playbackId}) async {}

  @override
  Future<void> dispose() async {
    _buffers.clear();
    _closed.clear();
  }
}

void main() {
  group('SpeakerBackend reference', () {
    test('ordered append and complete lifecycle', () async {
      final backend = _ReferenceSpeakerBackend();

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
      await backend.appendChunk(
        playbackId: playbackId,
        chunk: TtsAudioChunk(
          bytes: Uint8List.fromList([3]),
          requestId: '',
          sequenceNumber: 0,
          isLastChunk: true,
          timestamp: DateTime.now(),
          audioSpec: const TtsAudioSpec.mp3(),
        ),
      );

      await backend.finalizePlayback(playbackId: playbackId);
      await expectLater(
        () => backend.appendChunk(
          playbackId: playbackId,
          chunk: TtsAudioChunk(
            bytes: Uint8List.fromList([4]),
            requestId: '',
            sequenceNumber: 0,
            isLastChunk: false,
            timestamp: DateTime.now(),
            audioSpec: const TtsAudioSpec.mp3(),
          ),
        ),
        throwsStateError,
      );
    });

    test('stop closes playback', () async {
      final backend = _ReferenceSpeakerBackend();

      final playbackId = await backend.startPlayback(
        requestId: 'r2',
        audioSpec: const TtsAudioSpec.mp3(),
      );
      await backend.appendChunk(
        playbackId: playbackId,
        chunk: TtsAudioChunk(
          bytes: Uint8List.fromList([9]),
          requestId: '',
          sequenceNumber: 0,
          isLastChunk: true,
          timestamp: DateTime.now(),
          audioSpec: const TtsAudioSpec.mp3(),
        ),
      );
      await backend.stopPlayback(playbackId: playbackId, reason: 'cancelled');

      await expectLater(
        () => backend.appendChunk(
          playbackId: playbackId,
          chunk: TtsAudioChunk(
            bytes: Uint8List.fromList([10]),
            requestId: '',
            sequenceNumber: 0,
            isLastChunk: true,
            timestamp: DateTime.now(),
            audioSpec: const TtsAudioSpec.mp3(),
          ),
        ),
        throwsStateError,
      );
    });
  });
}
