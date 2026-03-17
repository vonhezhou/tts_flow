import 'dart:typed_data';

import '../core/tts_contracts.dart';
import '../core/tts_models.dart';

final class MemoryOutput implements TtsOutput {
  MemoryOutput({this.outputId = 'memory-output'});

  @override
  final String outputId;

  @override
  Set<TtsAudioFormat> get acceptedFormats => TtsAudioFormat.values.toSet();

  TtsOutputSession? _session;
  BytesBuilder? _buffer;

  @override
  Future<void> initSession(TtsOutputSession session) async {
    _session = session;
    _buffer = BytesBuilder(copy: false);
  }

  @override
  Future<void> consumeChunk(TtsChunk chunk) async {
    final session = _session;
    final buffer = _buffer;
    if (session == null || buffer == null) {
      throw StateError('MemoryOutput session is not initialized.');
    }
    if (chunk.requestId != session.requestId) {
      throw StateError('Chunk requestId does not match active session.');
    }
    buffer.add(chunk.bytes);
  }

  @override
  Future<TtsOutputArtifact> finalizeSession() async {
    final session = _session;
    final buffer = _buffer;
    if (session == null || buffer == null) {
      throw StateError('MemoryOutput session is not initialized.');
    }
    final audioBytes = buffer.takeBytes();
    _session = null;
    _buffer = null;
    return MemoryOutputArtifact(
      requestId: session.requestId,
      resolvedFormat: session.resolvedFormat,
      audioBytes: audioBytes,
      totalBytes: audioBytes.length,
    );
  }

  @override
  Future<void> onStop(String reason) async {
    _session = null;
    _buffer = null;
  }

  @override
  Future<void> dispose() async {
    _session = null;
    _buffer = null;
  }
}
