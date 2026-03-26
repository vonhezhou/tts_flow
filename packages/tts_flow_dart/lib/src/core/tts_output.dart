import 'package:tts_flow_dart/src/core/audio_artifact.dart';
import 'package:tts_flow_dart/src/core/audio_capability.dart';
import 'package:tts_flow_dart/src/core/audio_spec.dart';
import 'package:tts_flow_dart/src/core/synthesis_control.dart';
import 'package:tts_flow_dart/src/core/tts_chunk.dart';
import 'package:tts_flow_dart/src/core/tts_output_session.dart';

abstract interface class TtsOutput {
  String get outputId;
  Set<AudioCapability> get acceptedCapabilities;

  Future<void> initSession(TtsOutputSession session);
  Future<void> consumeChunk(TtsChunk chunk);
  Future<AudioArtifact> finalizeSession();

  Future<void> onCancel(SynthesisControl control);
  Future<void> dispose();
}

extension TtsOutputCapabilities on TtsOutput {
  bool acceptsSpec(TtsAudioSpec spec) {
    for (final capability in acceptedCapabilities) {
      if (capability.supports(spec)) {
        return true;
      }
    }
    return false;
  }
}
