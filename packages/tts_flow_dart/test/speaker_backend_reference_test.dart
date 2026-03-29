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
  Future<void> appendAudio({
    required String playbackId,
    required List<int> bytes,
  }) async {
    if (_closed.contains(playbackId)) {
      throw StateError('Playback already closed: $playbackId');
    }
    final buffer = _buffers[playbackId];
    if (buffer == null) {
      throw StateError('Unknown playbackId: $playbackId');
    }
    buffer.addAll(bytes);
  }

  @override
  Future<void> finalizeIngestion({required String playbackId}) async {
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

      await backend.appendAudio(playbackId: playbackId, bytes: [1, 2]);
      await backend.appendAudio(playbackId: playbackId, bytes: [3]);

      await backend.finalizeIngestion(playbackId: playbackId);
      await expectLater(
        () => backend.appendAudio(playbackId: playbackId, bytes: [4]),
        throwsStateError,
      );
    });

    test('stop closes playback', () async {
      final backend = _ReferenceSpeakerBackend();

      final playbackId = await backend.startPlayback(
        requestId: 'r2',
        audioSpec: const TtsAudioSpec.mp3(),
      );
      await backend.appendAudio(playbackId: playbackId, bytes: [9]);
      await backend.stopPlayback(playbackId: playbackId, reason: 'cancelled');

      await expectLater(
        () => backend.appendAudio(playbackId: playbackId, bytes: [10]),
        throwsStateError,
      );
    });
  });
}
