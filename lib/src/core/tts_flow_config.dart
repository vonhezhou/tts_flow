import 'package:tts_flow_dart/src/core/audio_spec.dart';
import 'package:tts_flow_dart/src/core/tts_policy.dart';

final class TtsFlowConfig {
  const TtsFlowConfig({
    this.preferredFormatOrder = const [
      TtsAudioFormat.mp3,
      TtsAudioFormat.opus,
      TtsAudioFormat.aac,
      TtsAudioFormat.pcm,
    ],
    this.queueFailurePolicy = TtsQueueFailurePolicy.failFast,
    this.pauseBufferPolicy = TtsPauseBufferPolicy.buffered,
    this.pauseBufferMaxBytes = 10 * 1024 * 1024,
  });

  final List<TtsAudioFormat> preferredFormatOrder;
  final TtsQueueFailurePolicy queueFailurePolicy;

  /// Determines how chunks produced by the engine are handled during pause.
  final TtsPauseBufferPolicy pauseBufferPolicy;

  /// Maximum number of bytes to accumulate in the pause buffer before logging
  /// a warning. Chunks continue to buffer beyond this limit and are not
  /// dropped.
  final int pauseBufferMaxBytes;
}
