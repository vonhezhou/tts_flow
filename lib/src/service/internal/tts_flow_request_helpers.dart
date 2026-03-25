part of 'package:tts_flow_dart/src/service/tts_flow.dart';

_RequestFailure _mapRequestFailureImpl(Object error, TtsRequest request) {
  final outputFailure = error is TtsOutputFailure ? error : null;
  final outputError = outputFailure?.error;
  final baseError = outputError ?? (error is TtsError ? error : null);
  final ttsError = baseError != null
      ? TtsError(
          code: baseError.code,
          message: baseError.message,
          requestId: baseError.requestId ?? request.requestId,
          cause: baseError.cause,
        )
      : TtsError(
          code: TtsErrorCode.internalError,
          message: 'Request processing failed.',
          requestId: request.requestId,
          cause: error,
        );

  return _RequestFailure(
    ttsError: ttsError,
    outputId: outputFailure?.outputId,
    outputError: outputError,
  );
}

Future<void> _cancelPendingAfterFailureImpl(TtsFlow service) async {
  final pending = service._scheduler.drain();
  for (final item in pending) {
    service.emitRequestEvent(
      TtsRequestEventType.requestCanceled,
      requestId: item.request.requestId,
      state: TtsRequestState.canceled,
    );
    unawaited(item.controller.close());
  }
}

TtsAudioSpec _resolveAudioSpecImpl(TtsFlow service, TtsRequest request) {
  return service._formatNegotiator.negotiateSpec(
    engineCapabilities: service._engine.supportedCapabilities,
    outputCapabilities: service._output.acceptedCapabilities,
    preferredOrder: service._config.preferredFormatOrder,
    requestId: request.requestId,
    preferredFormat: request.preferredFormat,
    preferredSampleRateHz: request.options?.sampleRateHz,
  );
}
