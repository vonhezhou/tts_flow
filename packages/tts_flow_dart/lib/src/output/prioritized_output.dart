import 'dart:async';

import 'package:tts_flow_dart/src/core/audio_artifact.dart';
import 'package:tts_flow_dart/src/core/audio_capability.dart';
import 'package:tts_flow_dart/src/core/synthesis_control.dart';
import 'package:tts_flow_dart/src/core/tts_auxiliary_output.dart';
import 'package:tts_flow_dart/src/core/tts_chunk.dart';
import 'package:tts_flow_dart/src/core/tts_output.dart';
import 'package:tts_flow_dart/src/core/tts_output_write_context.dart';

/// A [TtsOutput] with one backpressure-participating primary output and
/// optional non-blocking auxiliary observers.
///
/// Only [primary] participates in format negotiation and is awaited by the
/// synthesis path. [auxiliaries] are notified synchronously after the primary
/// accepts each lifecycle operation, but their work is never awaited. This
/// keeps a latency-critical playback output isolated from recording,
/// diagnostics, or application-owned processing.
///
/// This class intentionally provides no queue, buffering, retry, dropping, or
/// completion policy for an auxiliary output. An auxiliary that performs
/// asynchronous work owns those concerns itself. Use [MulticastOutput] when
/// every child output must receive a complete, backpressure-coupled stream.
final class PrioritizedOutput implements TtsOutput, PlaybackControllableOutput {
  PrioritizedOutput({
    required this.primary,
    List<TtsAuxiliaryOutput> auxiliaries = const [],
    this.outputId = 'prioritized-output',
  }) : _auxiliaries = List.unmodifiable(auxiliaries),
       _playbackCompletedController =
           StreamController<TtsOutputPlaybackCompletedEvent>.broadcast(),
       _playbackFailedController =
           StreamController<TtsOutputPlaybackFailedEvent>.broadcast(),
       _auxiliaryErrorController =
           StreamController<TtsAuxiliaryOutputError>.broadcast() {
    final ids = <String>{primary.outputId};
    for (final auxiliary in _auxiliaries) {
      if (!ids.add(auxiliary.outputId)) {
        throw ArgumentError.value(
          auxiliaries,
          'auxiliaries',
          'Output IDs must be unique. Duplicate: ${auxiliary.outputId}',
        );
      }
    }

    if (primary case final PlaybackAwareOutput playbackAware) {
      _playbackCompletedSubscription = playbackAware.playbackCompletedEvents
          .listen(_playbackCompletedController.add);
    }
    if (primary case final PlaybackFailureAwareOutput playbackFailureAware) {
      _playbackFailedSubscription = playbackFailureAware.playbackFailedEvents
          .listen(_playbackFailedController.add);
    }
  }

  /// The output that governs request success, format selection, and latency.
  final TtsOutput primary;

  final List<TtsAuxiliaryOutput> _auxiliaries;

  /// Non-blocking observers of the primary output write.
  List<TtsAuxiliaryOutput> get auxiliaries => _auxiliaries;

  @override
  final String outputId;

  final StreamController<TtsOutputPlaybackCompletedEvent>
  _playbackCompletedController;
  final StreamController<TtsOutputPlaybackFailedEvent>
  _playbackFailedController;
  final StreamController<TtsAuxiliaryOutputError> _auxiliaryErrorController;
  StreamSubscription<TtsOutputPlaybackCompletedEvent>?
  _playbackCompletedSubscription;
  StreamSubscription<TtsOutputPlaybackFailedEvent>? _playbackFailedSubscription;

  TtsOutputWriteContext? _writeContext;

  @override
  Set<AudioCapability> get inAudioCapabilities => primary.inAudioCapabilities;

  @override
  Stream<TtsOutputPlaybackCompletedEvent> get playbackCompletedEvents =>
      _playbackCompletedController.stream;

  @override
  Stream<TtsOutputPlaybackFailedEvent> get playbackFailedEvents =>
      _playbackFailedController.stream;

  /// Reports synchronous errors thrown by an auxiliary notification.
  ///
  /// Listening is optional. Errors sent here are intentionally not promoted to
  /// [TtsFlow.requestEvents], because they do not affect the request result.
  Stream<TtsAuxiliaryOutputError> get auxiliaryErrors =>
      _auxiliaryErrorController.stream;

  @override
  Future<void> init() async {
    await primary.init();
    _notifyAll(TtsAuxiliaryOutputStage.init, (auxiliary) => auxiliary.init());
  }

  @override
  Future<void> startWrite(TtsOutputWriteContext writeContext) async {
    await primary.startWrite(writeContext);
    _writeContext = writeContext;
    _notifyAll(
      TtsAuxiliaryOutputStage.startWrite,
      (auxiliary) => auxiliary.startWrite(writeContext),
    );
  }

  @override
  Future<void> writeChunk(TtsChunk chunk) async {
    final writeContext = _requireWriteContext();
    if (chunk.requestKey != writeContext.requestKey) {
      throw StateError('Chunk requestKey does not match active write.');
    }

    await primary.writeChunk(chunk);
    _notifyAll(
      TtsAuxiliaryOutputStage.writeChunk,
      (auxiliary) => auxiliary.writeChunk(chunk),
    );
  }

  @override
  Future<AudioArtifact> finishWrite() async {
    _requireWriteContext();
    final artifact = await primary.finishWrite();
    _notifyAll(
      TtsAuxiliaryOutputStage.finishWrite,
      (auxiliary) => auxiliary.finishWrite(),
    );
    _writeContext = null;
    return artifact;
  }

  @override
  Future<void> cancelWrite(SynthesisControl control) async {
    try {
      await primary.cancelWrite(control);
    } finally {
      _notifyAll(
        TtsAuxiliaryOutputStage.cancelWrite,
        (auxiliary) => auxiliary.cancelWrite(control),
      );
      _writeContext = null;
    }
  }

  @override
  bool hasActivePlayback(String requestKey) {
    final playbackOutput = primary;
    if (playbackOutput is PlaybackControllableOutput) {
      return (playbackOutput as PlaybackControllableOutput).hasActivePlayback(
        requestKey,
      );
    }
    return false;
  }

  @override
  Future<void> pausePlayback(String requestKey) {
    return _requirePlaybackOutput().pausePlayback(requestKey);
  }

  @override
  Future<void> resumePlayback(String requestKey) {
    return _requirePlaybackOutput().resumePlayback(requestKey);
  }

  @override
  Future<void> stopPlayback(String requestKey) {
    return _requirePlaybackOutput().stopPlayback(requestKey);
  }

  @override
  Future<void> dispose() async {
    try {
      await primary.dispose();
    } finally {
      _notifyAll(
        TtsAuxiliaryOutputStage.dispose,
        (auxiliary) => auxiliary.dispose(),
      );
      _writeContext = null;
      await _playbackCompletedSubscription?.cancel();
      await _playbackFailedSubscription?.cancel();
      await _playbackCompletedController.close();
      await _playbackFailedController.close();
      await _auxiliaryErrorController.close();
    }
  }

  TtsOutputWriteContext _requireWriteContext() {
    final writeContext = _writeContext;
    if (writeContext == null) {
      throw StateError('PrioritizedOutput write has not started.');
    }
    return writeContext;
  }

  PlaybackControllableOutput _requirePlaybackOutput() {
    final playbackOutput = primary;
    if (playbackOutput is PlaybackControllableOutput) {
      return playbackOutput as PlaybackControllableOutput;
    }
    throw StateError('Primary output does not support playback control.');
  }

  void _notifyAll(
    TtsAuxiliaryOutputStage stage,
    void Function(TtsAuxiliaryOutput auxiliary) notification,
  ) {
    for (final auxiliary in _auxiliaries) {
      try {
        notification(auxiliary);
      } catch (error, stackTrace) {
        _auxiliaryErrorController.add(
          TtsAuxiliaryOutputError(
            outputId: auxiliary.outputId,
            stage: stage,
            error: error,
            stackTrace: stackTrace,
            requestKey: _writeContext?.requestKey,
          ),
        );
      }
    }
  }
}
