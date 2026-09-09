import 'dart:typed_data';

import 'package:tts_flow_dart/src/base/pcm_descriptor.dart';
import 'package:tts_flow_dart/src/core/audio_artifact.dart';
import 'package:tts_flow_dart/src/core/audio_capability.dart';
import 'package:tts_flow_dart/src/core/synthesis_control.dart';
import 'package:tts_flow_dart/src/core/tts_chunk.dart';
import 'package:tts_flow_dart/src/core/tts_output.dart';
import 'package:tts_flow_dart/src/core/tts_output_write_context.dart';

final class MemoryOutput implements TtsOutput {
  MemoryOutput({this.outputId = 'memory-output'});

  @override
  final String outputId;

  @override
  Set<AudioCapability> get inAudioCapabilities => {
    PcmCapability(
      sampleRatesHz: {16000, 22050, 24000, 44100, 48000},
      bitsPerSample: {16},
      channels: {1, 2},
      encodings: {PcmEncoding.signedInt},
    ),
    const Mp3Capability(),
    const OpusCapability(),
    const AacCapability(),
  };

  TtsOutputWriteContext? _writeContext;
  BytesBuilder? _buffer;

  @override
  Future<void> init() async {}

  @override
  Future<void> startWrite(TtsOutputWriteContext writeContext) async {
    _writeContext = writeContext;
    _buffer = BytesBuilder(copy: false);
  }

  @override
  Future<void> writeChunk(TtsChunk chunk) async {
    final writeContext = _writeContext;
    final buffer = _buffer;
    if (writeContext == null || buffer == null) {
      throw StateError('MemoryOutput write has not started.');
    }

    if (chunk.requestKey != writeContext.requestKey) {
      throw StateError('Chunk requestKey does not match active write.');
    }

    if (chunk is! TtsAudioChunk) {
      return;
    }

    buffer.add(chunk.bytes);
  }

  @override
  Future<AudioArtifact> finishWrite() async {
    final writeContext = _writeContext;
    final buffer = _buffer;
    if (writeContext == null || buffer == null) {
      throw StateError('MemoryOutput write has not started.');
    }
    final audioBytes = buffer.takeBytes();
    _writeContext = null;
    _buffer = null;
    return InMemoryAudioArtifact(
      requestKey: writeContext.requestKey,
      audioSpec: writeContext.audioSpec,
      audioBytes: audioBytes,
      totalBytes: audioBytes.length,
    );
  }

  @override
  Future<void> cancelWrite(SynthesisControl control) async {
    _writeContext = null;
    _buffer = null;
  }

  @override
  Future<void> dispose() async {
    _writeContext = null;
    _buffer = null;
  }
}
