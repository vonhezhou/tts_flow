enum TtsErrorCode {
  invalidRequest,
  maxInputByteSizeExceeded,
  engineUnavailable,
  authFailed,
  networkError,
  timeout,
  unsupportedFormat,
  formatNegotiationFailed,
  outputWriteFailed,
  outputPlaybackFailed,
  canceled,
  internalError,
}

final class TtsError implements Exception {
  const TtsError({
    required this.code,
    required this.message,
    this.requestKey,
    this.cause,
  });

  final TtsErrorCode code;
  final String message;
  final String? requestKey;
  final Object? cause;

  @override
  String toString() =>
      'TtsError(code: $code, message: $message, requestKey: $requestKey)';
}

final class TtsOutputFailure implements Exception {
  const TtsOutputFailure({required this.outputId, required this.error});

  final String outputId;
  final TtsError error;

  @override
  String toString() =>
      'TtsOutputFailure(outputId: $outputId, error: ${error.toString()})';
}

Never throwAsTtsError(Object error, {String? requestKey}) {
  if (error is TtsError) {
    throw error;
  }
  throw TtsError(
    code: TtsErrorCode.internalError,
    message: 'Unexpected error during TTS operation.',
    requestKey: requestKey,
    cause: error,
  );
}
