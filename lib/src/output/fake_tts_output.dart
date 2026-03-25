import 'dart:typed_data';

import 'package:tts_flow_dart/src/base/pcm_descriptor.dart';
import 'package:tts_flow_dart/src/core/audio_artifact.dart';
import 'package:tts_flow_dart/src/core/audio_capability.dart';
import 'package:tts_flow_dart/src/core/audio_spec.dart';
import 'package:tts_flow_dart/src/core/tts_contracts.dart';
import 'package:tts_flow_dart/src/core/tts_models.dart';
import 'package:tts_flow_dart/src/core/tts_output.dart';

final class FakeTtsOutput implements TtsOutput {
  TtsOutputSession? _session;
  final BytesBuilder _buffer = BytesBuilder(copy: false);

  @override
  String get outputId => 'fake-output';

  @override
  Set<AudioCapability> get acceptedCapabilities => {
        PcmCapability(
          sampleRatesHz: {16000, 22050, 24000, 44100, 48000},
          bitsPerSample: {16},
          channels: {1, 2},
          encodings: {PcmEncoding.signedInt},
        ),
        const SimpleFormatCapability(format: TtsAudioFormat.wav),
        const SimpleFormatCapability(format: TtsAudioFormat.mp3),
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
  Future<AudioArtifact> finalizeSession() async {
    final session = _session;
    if (session == null) {
      throw StateError('No active output session.');
    }

    final bytes = _buffer.takeBytes();
    return InMemoryAudioArtifact(
      requestId: session.requestId,
      audioSpec: session.audioSpec,
      audioBytes: bytes,
      totalBytes: bytes.length,
    );
  }

  @override
  Future<void> onCancel(SynthesisControl control) async {}

  @override
  Future<void> dispose() async {
    _session = null;
    _buffer.clear();
  }
}
