import 'dart:typed_data';

import 'package:tts_flow_dart/src/base/pcm_descriptor.dart';
import 'package:tts_flow_dart/src/core/audio_artifact.dart';
import 'package:tts_flow_dart/src/core/audio_capability.dart';
import 'package:tts_flow_dart/src/core/audio_spec.dart';
import 'package:tts_flow_dart/src/core/synthesis_control.dart';
import 'package:tts_flow_dart/src/core/tts_chunk.dart';
import 'package:tts_flow_dart/src/core/tts_output.dart';
import 'package:tts_flow_dart/src/core/tts_output_session.dart';

final class MemoryOutput implements TtsOutput {
  MemoryOutput({this.outputId = 'memory-output'});

  @override
  final String outputId;

  @override
  Set<AudioCapability> get acceptedCapabilities => {
        PcmCapability(
          sampleRatesHz: {16000, 22050, 24000, 44100, 48000},
          bitsPerSample: {16},
          channels: {1, 2},
          encodings: {PcmEncoding.signedInt},
        ),
        const SimpleFormatCapability(format: TtsAudioFormat.mp3),
        const SimpleFormatCapability(format: TtsAudioFormat.opus),
        const SimpleFormatCapability(format: TtsAudioFormat.aac),
      };

  TtsOutputSession? _session;
  BytesBuilder? _buffer;

  @override
  Future<void> init() async {}

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
