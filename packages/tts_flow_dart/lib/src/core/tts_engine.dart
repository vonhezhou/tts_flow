import 'package:tts_flow_dart/src/core/audio_capability.dart';
import 'package:tts_flow_dart/src/core/audio_spec.dart';
import 'package:tts_flow_dart/src/core/synthesis_control.dart';
import 'package:tts_flow_dart/src/core/tts_chunk.dart';
import 'package:tts_flow_dart/src/core/tts_request.dart';
import 'package:tts_flow_dart/src/core/tts_voice.dart';

abstract interface class TtsEngine {
  String get engineId;
  bool get supportsStreaming;
  Set<AudioCapability> get supportedCapabilities;

  /// Returns voices supported by this engine.
  ///
  /// When [locale] is provided, engines should prefer returning voices that
  /// match the locale exactly (for example, en-US) or by language fallback
  /// (for example, en). Engines may return an empty list when no locale match
  /// is available.
  Future<List<TtsVoice>> getAvailableVoices({String? locale});

  /// Returns the engine default voice.
  Future<TtsVoice> getDefaultVoice();

  /// Returns a default voice for [locale] using engine-specific fallback.
  ///
  /// Engines should apply deterministic fallback, such as
  /// exact locale -> language match -> global default voice.
  Future<TtsVoice> getDefaultVoiceForLocale(String locale);

  Future<void> init();

  Stream<TtsChunk> synthesize(
    TtsRequest request,
    SynthesisControl control,
    TtsAudioSpec resolvedFormat,
  );

  Future<void> dispose();
}

extension TtsEngineCapabilities on TtsEngine {
  bool supportsSpec(TtsAudioSpec spec) {
    for (final capability in supportedCapabilities) {
      if (capability.supports(spec)) {
        return true;
      }
    }
    return false;
  }
}
