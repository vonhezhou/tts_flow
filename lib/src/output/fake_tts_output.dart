import 'dart:typed_data';

import '../core/tts_contracts.dart';
import '../core/tts_models.dart';

final class FakeTtsOutput implements TtsOutput {
  TtsOutputSession? _session;
  final BytesBuilder _buffer = BytesBuilder(copy: false);

  @override
  String get outputId => 'fake-output';

  @override
  Set<TtsAudioFormat> get acceptedFormats => {
        TtsAudioFormat.pcm,
        TtsAudioFormat.wav,
        TtsAudioFormat.mp3,
      };

  @override
  Future<void> initSession(TtsOutputSession session) async {
    _session = session;
    _buffer.clear();
  }

  @override
  Future<void> consumeChunk(TtsChunk chunk) async {
    _buffer.add(chunk.bytes);
  }

  @override
  Future<TtsOutputArtifact> finalizeSession() async {
    final session = _session;
    if (session == null) {
      throw StateError('No active output session.');
    }

    final bytes = _buffer.takeBytes();
    return MemoryOutputArtifact(
      requestId: session.requestId,
      resolvedFormat: session.resolvedFormat,
      audioBytes: bytes,
      totalBytes: bytes.length,
    );
  }

  @override
  Future<void> onPause() async {}

  @override
  Future<void> onResume() async {}

  @override
  Future<void> onStop(String reason) async {}

  @override
  Future<void> dispose() async {
    _session = null;
    _buffer.clear();
  }
}
