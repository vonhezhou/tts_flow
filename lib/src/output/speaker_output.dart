import '../core/tts_contracts.dart';
import '../core/tts_models.dart';

abstract interface class SpeakerBackend {
  Set<AudioCapability> get supportedCapabilities;

  Future<String> startPlayback({
    required String requestId,
    required TtsAudioSpec audioSpec,
  });

  Future<void> appendAudio({
    required String playbackId,
    required List<int> bytes,
  });

  Future<Duration> completePlayback({
    required String playbackId,
  });

  Future<void> stopPlayback({
    required String playbackId,
    String? reason,
  });

  Future<void> pausePlayback({required String playbackId});

  Future<void> resumePlayback({required String playbackId});

  Future<void> dispose();
}

final class SpeakerOutput implements TtsOutput {
  SpeakerOutput({
    required SpeakerBackend backend,
    this.outputId = 'speaker-output',
  }) : _backend = backend;

  final SpeakerBackend _backend;

  @override
  final String outputId;

  @override
  Set<AudioCapability> get acceptedCapabilities =>
      _backend.supportedCapabilities;

  TtsOutputSession? _session;
  String? _playbackId;

  @override
  Future<void> initSession(TtsOutputSession session) async {
    _session = session;
    _playbackId = await _backend.startPlayback(
      requestId: session.requestId,
      audioSpec: session.audioSpec,
    );
  }

  @override
  Future<void> consumeChunk(TtsChunk chunk) async {
    final session = _session;
    final playbackId = _playbackId;
    if (session == null || playbackId == null) {
      throw StateError('SpeakerOutput session is not initialized.');
    }
    if (chunk.requestId != session.requestId) {
      throw StateError('Chunk requestId does not match active session.');
    }

    await _backend.appendAudio(playbackId: playbackId, bytes: chunk.bytes);
  }

  @override
  Future<AudioArtifact> finalizeSession() async {
    final session = _session;
    final playbackId = _playbackId;
    if (session == null || playbackId == null) {
      throw StateError('SpeakerOutput session is not initialized.');
    }

    final duration = await _backend.completePlayback(playbackId: playbackId);
    _session = null;
    _playbackId = null;

    return PlaybackAudioArtifact(
      requestId: session.requestId,
      audioSpec: session.audioSpec,
      playbackId: playbackId,
      playbackDuration: duration,
    );
  }

  @override
  Future<void> onCancel(SynthesisControl control) async {
    final playbackId = _playbackId;
    if (playbackId != null) {
      final reason = control.cancelMessage ?? control.cancelReason?.name;
      await _backend.stopPlayback(
        playbackId: playbackId,
        reason: reason,
      );
    }
    _session = null;
    _playbackId = null;
  }

  @override
  Future<void> dispose() async {
    final control = SynthesisControl()..cancel(CancelReason.serviceDispose);
    await onCancel(control);
    await _backend.dispose();
  }
}
