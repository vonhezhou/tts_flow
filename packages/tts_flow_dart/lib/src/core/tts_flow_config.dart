import 'package:tts_flow_dart/src/core/audio_spec.dart';
import 'package:tts_flow_dart/src/core/tts_policy.dart';
import 'package:tts_flow_dart/src/core/tts_synthesis_admission_policy.dart';

final class TtsFlowConfig {
  const TtsFlowConfig({
    this.preferredFormatOrder = const [
      TtsAudioFormat.mp3,
      TtsAudioFormat.opus,
      TtsAudioFormat.aac,
      TtsAudioFormat.pcm,
    ],
    this.queueFailurePolicy = TtsQueueFailurePolicy.failFast,
    this.synthesisAdmissionPolicy = const TtsEagerSynthesisAdmissionPolicy(),
    this.activeSynthesisShutdownTimeout = const Duration(seconds: 5),
  });

  final List<TtsAudioFormat> preferredFormatOrder;
  final TtsQueueFailurePolicy queueFailurePolicy;

  /// Determines how far synthesis may run ahead of physical playback.
  ///
  /// The default keeps the existing eager behavior: when one request's output
  /// write ends, the next queued request may begin even if prior audio is
  /// still playing.
  final TtsSynthesisAdmissionPolicy synthesisAdmissionPolicy;

  /// Maximum time [TtsFlow.dispose] waits for an active engine stream to
  /// observe cancellation before it invokes [TtsEngine.dispose].
  ///
  /// Outputs are disposed only after the active stream has actually exited, so
  /// a late engine callback can never write to an already-disposed output.
  /// Set this to `null` when the caller prefers to wait indefinitely before
  /// invoking engine disposal. Engines must still observe [SynthesisControl]
  /// promptly and make [TtsEngine.dispose] complete only after their own work
  /// has stopped.
  final Duration? activeSynthesisShutdownTimeout;
}
