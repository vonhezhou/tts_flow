import 'dart:async';
import 'dart:developer' as dev;

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
  bool _isPaused = false;
  SynthesisControl? _activeControl;
  final List<TtsChunk> _pauseBuffer = [];
  int _pauseBufferBytes = 0;

  Stream<TtsQueueEvent> get queueEvents => _queueEventsController.stream;
  Stream<TtsRequestEvent> get requestEvents => _requestEventsController.stream;
  bool get isPaused => _isPaused;

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
    _isPaused = true;
  }

  Future<void> resumeCurrent() async {
    _ensureNotDisposed();
    _isPaused = false;
    unawaited(_processQueue());
  }

  Future<void> stopCurrent() async {
    _ensureNotDisposed();
    _activeControl?.cancel(CancelReason.stopCurrent);
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

    _activeControl?.cancel(CancelReason.serviceDispose);
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
        // Pause gates starting the next request. Active request handling
        // continues in-loop using buffering/passthrough policy.
        if (_isPaused) {
          break;
        }

        final item = _scheduler.dequeue();
        final request = item.request;
        final control = SynthesisControl();
        _activeControl = control;

        _emitQueueEvent(TtsQueueEventType.requestDequeued,
            requestId: request.requestId);
        _emitRequestEvent(
          TtsRequestEventType.requestStarted,
          requestId: request.requestId,
          state: TtsRequestState.running,
        );

        try {
          final audioSpec = _resolveAudioSpec(request);
          await _output.initSession(
            TtsOutputSession(
              requestId: request.requestId,
              audioSpec: audioSpec,
              voice: request.voice,
              options: request.options,
              params: request.params,
            ),
          );

          await for (final chunk
              in _engine.synthesize(request, control, audioSpec)) {
            if (control.isCanceled) {
              break;
            }
            // Flush any buffered chunks before processing new ones post-resume.
            if (_pauseBuffer.isNotEmpty && !_isPaused) {
              await _flushPauseBuffer(item, request, control);
              if (control.isCanceled) break;
            }
            if (_isPaused &&
                _config.pauseBufferPolicy == TtsPauseBufferPolicy.buffered) {
              _pauseBuffer.add(chunk);
              final newBytes = _pauseBufferBytes + chunk.bytes.length;
              if (_pauseBufferBytes <= _config.pauseBufferMaxBytes &&
                  newBytes > _config.pauseBufferMaxBytes) {
                dev.log(
                  'TTS pause buffer exceeded ${_config.pauseBufferMaxBytes} '
                  'bytes (current: $newBytes); chunks continue to accumulate.',
                  name: 'flutter_uni_tts',
                  level: 900,
                );
              }
              _pauseBufferBytes = newBytes;
              continue;
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
          // Engine stream exhausted. If it finished while still paused,
          // wait for resume and then flush the remaining buffer.
          if (!control.isCanceled && _pauseBuffer.isNotEmpty) {
            while (_isPaused && !_isDisposed && !control.isCanceled) {
              await Future<void>.delayed(const Duration(milliseconds: 20));
            }
            if (!control.isCanceled) {
              await _flushPauseBuffer(item, request, control);
            }
          }

          if (control.isCanceled) {
            await _output.onCancel(control);
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
          final failure = _mapRequestFailure(error, request);
          _emitRequestEvent(
            TtsRequestEventType.requestFailed,
            requestId: request.requestId,
            state: TtsRequestState.failed,
            error: failure.ttsError,
            outputId: failure.outputId,
            outputError: failure.outputError,
          );
          item.controller.addError(failure.ttsError);
          unawaited(item.controller.close());

          if (_config.queueFailurePolicy == TtsQueueFailurePolicy.failFast) {
            _isHalted = true;
            _emitQueueEvent(TtsQueueEventType.queueHalted,
                requestId: request.requestId);
            await _cancelPendingAfterFailure();
            break;
          }
        } finally {
          _activeControl = null;
          _pauseBuffer.clear();
          _pauseBufferBytes = 0;
        }

        if (_isHalted) {
          break;
        }
      }
    } finally {
      _isProcessing = false;
    }
  }

  _RequestFailure _mapRequestFailure(Object error, TtsRequest request) {
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

  TtsAudioSpec _resolveAudioSpec(TtsRequest request) {
    return _formatNegotiator.negotiateSpec(
      engineCapabilities: _engine.supportedCapabilities,
      outputCapabilities: _output.acceptedCapabilities,
      preferredOrder: _config.preferredFormatOrder,
      requestId: request.requestId,
      preferredFormat: request.preferredFormat,
      preferredSampleRateHz: request.options?.sampleRateHz,
    );
  }

  Future<void> _flushPauseBuffer(
    _QueuedRequest item,
    TtsRequest request,
    SynthesisControl control,
  ) async {
    final toFlush = List<TtsChunk>.of(_pauseBuffer);
    _pauseBuffer.clear();
    _pauseBufferBytes = 0;
    for (final chunk in toFlush) {
      if (control.isCanceled) break;
      await _output.consumeChunk(chunk);
      item.controller.add(chunk);
      _emitRequestEvent(
        TtsRequestEventType.requestChunkReceived,
        requestId: request.requestId,
        state: TtsRequestState.running,
        chunk: chunk,
      );
    }
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

final class _RequestFailure {
  const _RequestFailure({
    required this.ttsError,
    required this.outputId,
    required this.outputError,
  });

  final TtsError ttsError;
  final String? outputId;
  final TtsError? outputError;
}
