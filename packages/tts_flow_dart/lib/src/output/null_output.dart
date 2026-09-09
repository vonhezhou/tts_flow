import 'dart:typed_data';

import 'package:tts_flow_dart/src/core/audio_artifact.dart';
import 'package:tts_flow_dart/src/core/audio_capability.dart';
import 'package:tts_flow_dart/src/core/synthesis_control.dart';
import 'package:tts_flow_dart/src/core/tts_chunk.dart';
import 'package:tts_flow_dart/src/core/tts_output.dart';
import 'package:tts_flow_dart/src/core/tts_output_write_context.dart';

/// Sink output that discards all incoming audio bytes, similar to /dev/null.
final class NullOutput implements TtsOutput {
  NullOutput({this.outputId = 'null-output'});

  @override
  final String outputId;

  @override
  Set<AudioCapability> get inAudioCapabilities => {
    PcmCapability.wav(),
    const Mp3Capability(),
    const OpusCapability(),
    const AacCapability(),
  };

  TtsOutputWriteContext? _writeContext;

  @override
  Future<void> init() async {}

  @override
  Future<void> startWrite(TtsOutputWriteContext writeContext) async {
    _writeContext = writeContext;
  }

  @override
  Future<void> writeChunk(TtsChunk chunk) async {
    final writeContext = _writeContext;
    if (writeContext == null) {
      throw StateError('NullOutput write has not started.');
    }
    if (chunk.requestKey != writeContext.requestKey) {
      throw StateError('Chunk requestKey does not match active write.');
    }
  }

  @override
  Future<AudioArtifact> finishWrite() async {
    final writeContext = _writeContext;
    if (writeContext == null) {
      throw StateError('NullOutput write has not started.');
    }
    _writeContext = null;
    return InMemoryAudioArtifact(
      requestKey: writeContext.requestKey,
      audioSpec: writeContext.audioSpec,
      audioBytes: Uint8List(0),
      totalBytes: 0,
    );
  }

  @override
  Future<void> cancelWrite(SynthesisControl control) async {
    _writeContext = null;
  }

  @override
  Future<void> dispose() async {
    _writeContext = null;
  }
}
