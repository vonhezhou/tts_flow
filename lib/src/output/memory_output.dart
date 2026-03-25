import 'dart:typed_data';

import 'package:tts_flow_dart/tts_flow_dart.dart';

final class MemoryOutput implements TtsOutput {
  MemoryOutput({this.outputId = 'memory-output'});

  @override
  final String outputId;

  @override
  Set<AudioCapability> get acceptedCapabilities => TtsAudioFormat.values
      .map((format) => SimpleFormatCapability(format: format))
      .toSet();

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
  Future<AudioArtifact> finalizeSession() async {
    final session = _session;
    final buffer = _buffer;
    if (session == null || buffer == null) {
      throw StateError('MemoryOutput session is not initialized.');
    }
    final audioBytes = buffer.takeBytes();
    _session = null;
    _buffer = null;
    return InMemoryAudioArtifact(
      requestId: session.requestId,
      audioSpec: session.audioSpec,
      audioBytes: audioBytes,
      totalBytes: audioBytes.length,
    );
  }

  @override
  Future<void> onCancel(SynthesisControl control) async {
    _session = null;
    _buffer = null;
  }

  @override
  Future<void> dispose() async {
    _session = null;
    _buffer = null;
  }
}
