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
  });

  final List<TtsAudioFormat> preferredFormatOrder;
  final TtsQueueFailurePolicy queueFailurePolicy;
}
