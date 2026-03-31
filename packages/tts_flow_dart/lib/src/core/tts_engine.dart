import 'package:tts_flow_dart/src/core/audio_capability.dart';
import 'package:tts_flow_dart/src/core/audio_spec.dart';
import 'package:tts_flow_dart/src/core/synthesis_control.dart';
import 'package:tts_flow_dart/src/core/tts_chunk.dart';
import 'package:tts_flow_dart/src/core/tts_request.dart';
import 'package:tts_flow_dart/src/core/tts_voice.dart';

/// Engine contract that turns text requests into synthesized audio chunks.
///
/// Typical engine lifecycle:
/// 1. [init] is called once before any synthesis.
/// 2. [synthesize] is called per request using a format already negotiated by
///    the service.
/// 3. [dispose] is called when the service is shutting down.
///
/// Implementer expectations:
/// - [engineId] should be stable and unique enough for diagnostics.
/// - [outAudioCapabilities] must reflect real format support.
/// - [synthesize] should emit ordered chunks with the same request id as
///   [TtsRequest.requestId].
/// - [supportsStreaming] should indicate whether chunks can arrive incrementally
///   before synthesis completes.
abstract interface class TtsEngine {
  /// Stable identifier for this engine implementation.
  String get engineId;

  /// Whether [synthesize] can stream chunks incrementally.
  ///
  /// When false, implementations usually buffer internally and emit chunks only
  /// after full synthesis is available.
  bool get supportsStreaming;

  /// Audio capabilities that this engine can synthesize.
  ///
  /// Capability negotiation uses this set against output capabilities to choose
  /// a request format.
  Set<AudioCapability> get outAudioCapabilities;

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

  /// Initializes transport, auth, and other reusable engine resources.
  ///
  /// Implementations should make repeated calls safe where practical.
  Future<void> init();

  /// Synthesizes [request] into an ordered stream of [TtsChunk].
  ///
  /// [resolvedFormat] is already negotiated and should be treated as the target
  /// output format for this request. Implementations should observe cancellation
  /// signals from [control] and terminate promptly when cancelled.
  Stream<TtsChunk> synthesize(
    TtsRequest request,
    SynthesisControl control,
    TtsAudioSpec resolvedFormat,
  );

  /// Releases resources held by this engine.
  ///
  /// This should stop active synthesis work and clean up network or native
  /// handles if present.
  Future<void> dispose();
}

extension TtsEngineCapabilities on TtsEngine {
  /// Returns true when any supported capability can synthesize [spec].
  bool supportsSpec(TtsAudioSpec spec) {
    for (final capability in outAudioCapabilities) {
      if (capability.supports(spec)) {
        return true;
      }
    }
    return false;
  }
}
