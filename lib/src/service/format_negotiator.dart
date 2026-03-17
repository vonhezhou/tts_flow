import '../core/tts_errors.dart';
import '../core/tts_models.dart';

final class TtsFormatNegotiator {
  const TtsFormatNegotiator();

  TtsAudioFormat negotiate({
    required Set<TtsAudioFormat> engineFormats,
    required Set<TtsAudioFormat> outputFormats,
    required List<TtsAudioFormat> preferredOrder,
    required String requestId,
    TtsAudioFormat? preferredFormat,
  }) {
    final intersection = engineFormats.intersection(outputFormats);

    if (intersection.isEmpty) {
      throw TtsError(
        code: TtsErrorCode.formatNegotiationFailed,
        message: 'Engine and output do not share a common audio format.',
        requestId: requestId,
      );
    }

    if (preferredFormat != null && intersection.contains(preferredFormat)) {
      return preferredFormat;
    }

    for (final format in preferredOrder) {
      if (intersection.contains(format)) {
        return format;
      }
    }

    throw TtsError(
      code: TtsErrorCode.formatNegotiationFailed,
      message: 'No compatible format found using preferred format order.',
      requestId: requestId,
    );
  }
}
