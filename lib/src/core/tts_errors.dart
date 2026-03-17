enum TtsErrorCode {
  invalidRequest,
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
    this.requestId,
    this.cause,
  });

  final TtsErrorCode code;
  final String message;
  final String? requestId;
  final Object? cause;

  @override
  String toString() =>
      'TtsError(code: $code, message: $message, requestId: $requestId)';
}
