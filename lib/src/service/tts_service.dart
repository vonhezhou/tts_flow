import 'dart:async';

import '../core/tts_contracts.dart';
import '../core/tts_errors.dart';
import '../core/tts_models.dart';
import 'format_negotiator.dart';
import 'queue_scheduler.dart';
import 'tts_events.dart';

final class TtsService {
  TtsService({
    required TtsEngine engine,
    required TtsOutput output,
    TtsServiceConfig? config,
  })  : _engine = engine,
        _output = output,
        _config = config ?? const TtsServiceConfig();

  final TtsEngine _engine;
  final TtsOutput _output;
  final TtsServiceConfig _config;
  final TtsFormatNegotiator _formatNegotiator = const TtsFormatNegotiator();
  final QueueScheduler<_QueuedRequest> _scheduler =
      QueueScheduler<_QueuedRequest>();

  final StreamController<TtsQueueEvent> _queueEventsController =
      StreamController<TtsQueueEvent>.broadcast();
  final StreamController<TtsRequestEvent> _requestEventsController =
      StreamController<TtsRequestEvent>.broadcast();

  bool _isProcessing = false;
  bool _isDisposed = false;
  bool _isHalted = false;
  TtsControlToken? _activeControlToken;

  Stream<TtsQueueEvent> get queueEvents => _queueEventsController.stream;
  Stream<TtsRequestEvent> get requestEvents => _requestEventsController.stream;

  Stream<TtsChunk> speak(TtsRequest request) {
    _ensureNotDisposed();

    if (_isHalted) {
      _isHalted = false;
    }

    final controller = StreamController<TtsChunk>();
    final queued = _QueuedRequest(request: request, controller: controller);
    _scheduler.enqueue(queued);

    _emitRequestEvent(
      TtsRequestEventType.requestQueued,
      requestId: request.requestId,
      state: TtsRequestState.queued,
    );
    _emitQueueEvent(TtsQueueEventType.requestEnqueued,
        requestId: request.requestId);

    unawaited(_processQueue());
    return controller.stream;
  }

  Future<void> pauseCurrent() async {
    _ensureNotDisposed();
    _activeControlToken?.pause();
  }

  Future<void> resumeCurrent() async {
    _ensureNotDisposed();
    _activeControlToken?.resume();
  }

  Future<void> stopCurrent() async {
    _ensureNotDisposed();
    _activeControlToken?.stop();
  }

  Future<int> clearQueue() async {
    _ensureNotDisposed();
    final pending = _scheduler.drain();
    for (final item in pending) {
      _emitRequestEvent(
        TtsRequestEventType.requestCanceled,
        requestId: item.request.requestId,
        state: TtsRequestState.canceled,
      );
      unawaited(item.controller.close());
    }

    if (pending.isNotEmpty) {
      _emitQueueEvent(TtsQueueEventType.queueCleared);
    }
    return pending.length;
  }

  Future<void> dispose() async {
    if (_isDisposed) {
      return;
    }

    await stopCurrent();
    await clearQueue();
    await _engine.dispose();
    await _output.dispose();
    _isDisposed = true;
    await _queueEventsController.close();
    await _requestEventsController.close();
  }

  Future<void> _processQueue() async {
    if (_isProcessing || _isDisposed) {
      return;
    }
    _isProcessing = true;

    try {
      while (!_scheduler.isEmpty && !_isDisposed) {
        final item = _scheduler.dequeue();
        final request = item.request;
        final controlToken = TtsControlToken();
        _activeControlToken = controlToken;

        _emitQueueEvent(TtsQueueEventType.requestDequeued,
            requestId: request.requestId);
        _emitRequestEvent(
          TtsRequestEventType.requestStarted,
          requestId: request.requestId,
          state: TtsRequestState.running,
        );

        try {
          final resolvedFormat = _resolveFormat(request);
          await _output.initSession(
            TtsOutputSession(
              requestId: request.requestId,
              resolvedFormat: resolvedFormat,
            ),
          );

          await for (final chunk
              in _engine.synthesize(request, controlToken, resolvedFormat)) {
            if (controlToken.isStopped) {
              break;
            }
            await _output.consumeChunk(chunk);
            item.controller.add(chunk);
            _emitRequestEvent(
              TtsRequestEventType.requestChunkReceived,
              requestId: request.requestId,
              state: TtsRequestState.running,
              chunk: chunk,
            );
          }

          if (controlToken.isStopped) {
            await _output.onStop('stopCurrent');
            _emitRequestEvent(
              TtsRequestEventType.requestStopped,
              requestId: request.requestId,
              state: TtsRequestState.stopped,
            );
          } else {
            await _output.finalizeSession();
            _emitRequestEvent(
              TtsRequestEventType.requestCompleted,
              requestId: request.requestId,
              state: TtsRequestState.completed,
            );
          }

          unawaited(item.controller.close());
        } catch (error) {
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

          _emitRequestEvent(
            TtsRequestEventType.requestFailed,
            requestId: request.requestId,
            state: TtsRequestState.failed,
            error: ttsError,
            outputId: outputFailure?.outputId,
            outputError: outputError,
          );
          item.controller.addError(ttsError);
          unawaited(item.controller.close());

          _isHalted = true;
          _emitQueueEvent(TtsQueueEventType.queueHalted,
              requestId: request.requestId);
          await _cancelPendingAfterFailure();
          break;
        } finally {
          _activeControlToken = null;
        }
      }
    } finally {
      _isProcessing = false;
    }
  }

  Future<void> _cancelPendingAfterFailure() async {
    final pending = _scheduler.drain();
    for (final item in pending) {
      _emitRequestEvent(
        TtsRequestEventType.requestCanceled,
        requestId: item.request.requestId,
        state: TtsRequestState.canceled,
      );
      unawaited(item.controller.close());
    }
  }

  TtsAudioFormat _resolveFormat(TtsRequest request) {
    return _formatNegotiator.negotiate(
      engineFormats: _engine.supportedFormats,
      outputFormats: _output.acceptedFormats,
      preferredOrder: _config.preferredFormatOrder,
      requestId: request.requestId,
      preferredFormat: request.preferredFormat,
    );
  }

  void _emitQueueEvent(TtsQueueEventType type, {String? requestId}) {
    _queueEventsController.add(
      TtsQueueEvent(
        type: type,
        requestId: requestId,
        timestamp: DateTime.now().toUtc(),
        queueLength: _scheduler.length,
      ),
    );
  }

  void _emitRequestEvent(
    TtsRequestEventType type, {
    required String requestId,
    TtsRequestState? state,
    TtsChunk? chunk,
    TtsError? error,
    String? outputId,
    TtsError? outputError,
  }) {
    _requestEventsController.add(
      TtsRequestEvent(
        type: type,
        requestId: requestId,
        timestamp: DateTime.now().toUtc(),
        state: state,
        chunk: chunk,
        error: error,
        outputId: outputId,
        outputError: outputError,
      ),
    );
  }

  void _ensureNotDisposed() {
    if (_isDisposed) {
      throw StateError('TtsService is disposed.');
    }
  }
}

final class _QueuedRequest {
  const _QueuedRequest({required this.request, required this.controller});

  final TtsRequest request;
  final StreamController<TtsChunk> controller;
}
