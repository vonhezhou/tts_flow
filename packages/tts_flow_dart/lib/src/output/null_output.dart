import 'dart:typed_data';

import 'package:tts_flow_dart/src/core/audio_artifact.dart';
import 'package:tts_flow_dart/src/core/audio_capability.dart';
import 'package:tts_flow_dart/src/core/audio_spec.dart';
import 'package:tts_flow_dart/src/core/synthesis_control.dart';
import 'package:tts_flow_dart/src/core/tts_chunk.dart';
import 'package:tts_flow_dart/src/core/tts_output.dart';
import 'package:tts_flow_dart/src/core/tts_output_session.dart';

/// Sink output that discards all incoming audio bytes, similar to /dev/null.
final class NullOutput implements TtsOutput {
  NullOutput({this.outputId = 'null-output'});

  @override
  final String outputId;

  @override
  Set<AudioCapability> get acceptedCapabilities => TtsAudioFormat.values
      .map((format) => SimpleFormatCapability(format: format))
      .toSet();

  TtsOutputSession? _session;

  @override
  Future<void> initSession(TtsOutputSession session) async {
    _session = session;
  }

  @override
  Future<void> consumeChunk(TtsChunk chunk) async {
    final session = _session;
    if (session == null) {
      throw StateError('NullOutput session is not initialized.');
    }
    if (chunk.requestId != session.requestId) {
      throw StateError('Chunk requestId does not match active session.');
    }
  }

  @override
  Future<AudioArtifact> finalizeSession() async {
    final session = _session;
    if (session == null) {
      throw StateError('NullOutput session is not initialized.');
    }
    _session = null;
    return InMemoryAudioArtifact(
      requestId: session.requestId,
      audioSpec: session.audioSpec,
      audioBytes: Uint8List(0),
      totalBytes: 0,
    );
  }

  @override
  Future<void> onCancel(SynthesisControl control) async {
    _session = null;
  }

  @override
  Future<void> dispose() async {
    _session = null;
  }
}
