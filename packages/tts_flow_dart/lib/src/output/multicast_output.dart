import 'dart:async';

import 'package:tts_flow_dart/src/core/audio_artifact.dart';
import 'package:tts_flow_dart/src/core/audio_capability.dart';
import 'package:tts_flow_dart/src/core/synthesis_control.dart';
import 'package:tts_flow_dart/src/core/tts_chunk.dart';
import 'package:tts_flow_dart/src/core/tts_errors.dart';
import 'package:tts_flow_dart/src/core/tts_output.dart';
import 'package:tts_flow_dart/src/core/tts_output_session.dart';
import 'package:tts_flow_dart/src/core/tts_policy.dart';
import 'package:tts_flow_dart/src/output/capability_intersection.dart';

enum MulticastOutputErrorPolicy {
  /// If any individual output fails,
  /// the entire Multicast output fails immediately.
  failFast,

  /// If any individual output fails,
  /// the error is recorded but the Multicast output
  /// continues operating with the remaining outputs.
  bestEffort,
}

/// A TtsOutput that wraps multiple child outputs
/// and forwards all calls to them.
final class MulticastOutput implements TtsOutput, PlaybackControllableOutput {
  MulticastOutput({
    required List<TtsOutput> outputs,
    this.outputId = 'multicast-output',
    this.errorPolicy = MulticastOutputErrorPolicy.bestEffort,
  }) : _outputs = List.unmodifiable(outputs),
       _playbackCompletedController =
           StreamController<TtsOutputPlaybackCompletedEvent>.broadcast(),
       _playbackFailedController =
           StreamController<TtsOutputPlaybackFailedEvent>.broadcast() {
    if (_outputs.isEmpty) {
      throw ArgumentError.value(outputs, 'outputs', 'Must not be empty.');
    }

    final ids = <String>{};
    for (final output in _outputs) {
      if (!ids.add(output.outputId)) {
        throw ArgumentError.value(
          outputs,
          'outputs',
          'Output IDs must be unique. Duplicate: ${output.outputId}',
        );
      }
    }

    for (final output in _outputs) {
      if (output case final PlaybackAwareOutput playbackAwareOutput) {
        _playbackCompletedSubscriptions.add(
          playbackAwareOutput.playbackCompletedEvents.listen(
            (event) => _forwardPlaybackCompleted(output, event),
          ),
        );
      }
      if (output case final PlaybackFailureAwareOutput failureAwareOutput) {
        _playbackFailedSubscriptions.add(
          failureAwareOutput.playbackFailedEvents.listen(
            (event) => _forwardPlaybackFailed(output, event),
          ),
        );
      }
    }
  }

  final List<TtsOutput> _outputs;

  @override
  final String outputId;

  final MulticastOutputErrorPolicy errorPolicy;
  final StreamController<TtsOutputPlaybackCompletedEvent>
  _playbackCompletedController;
  final StreamController<TtsOutputPlaybackFailedEvent>
  _playbackFailedController;
  final List<StreamSubscription<TtsOutputPlaybackCompletedEvent>>
  _playbackCompletedSubscriptions =
      <StreamSubscription<TtsOutputPlaybackCompletedEvent>>[];
  final List<StreamSubscription<TtsOutputPlaybackFailedEvent>>
  _playbackFailedSubscriptions =
      <StreamSubscription<TtsOutputPlaybackFailedEvent>>[];

  TtsOutputSession? _session;
  final Map<String, TtsOutput> _activeOutputs = <String, TtsOutput>{};
  final Map<String, TtsError> _outputErrors = <String, TtsError>{};
  final Map<String, Set<PlaybackControllableOutput>>
  _playbackControlsByRequest = <String, Set<PlaybackControllableOutput>>{};

  @override
  Stream<TtsOutputPlaybackCompletedEvent> get playbackCompletedEvents =>
      _playbackCompletedController.stream;

  @override
  Stream<TtsOutputPlaybackFailedEvent> get playbackFailedEvents =>
      _playbackFailedController.stream;

  @override
  Set<AudioCapability> get inAudioCapabilities {
    var current = _outputs.first.inAudioCapabilities.toSet();
    for (final output in _outputs.skip(1)) {
      current = intersectCapabilities(current, output.inAudioCapabilities);
      if (current.isEmpty) {
        break;
      }
    }
    return current;
  }

  @override
  Future<void> init() async {
    TtsOutputFailure? firstFailure;
    for (final output in _outputs) {
      try {
        await output.init();
      } catch (error) {
        final converted = _toOutputError(
          error,
          requestId: null,
          stage: 'init',
          outputId: output.outputId,
        );
        _outputErrors[output.outputId] = converted;
        firstFailure ??= TtsOutputFailure(
          outputId: output.outputId,
          error: converted,
        );
      }
    }
    if (firstFailure != null &&
        errorPolicy == MulticastOutputErrorPolicy.failFast) {
      throw firstFailure;
    }
  }

  @override
  Future<void> initSession(TtsOutputSession session) async {
    _session = session;
    _activeOutputs.clear();
    _outputErrors.clear();

    for (final output in _outputs) {
      try {
        await output.initSession(session);
        _activeOutputs[output.outputId] = output;
        if (output case final PlaybackControllableOutput playbackOutput) {
          _playbackControlsByRequest
              .putIfAbsent(
                session.requestId,
                () => <PlaybackControllableOutput>{},
              )
              .add(playbackOutput);
        }
      } catch (error) {
        final converted = _toOutputError(
          error,
          requestId: session.requestId,
          stage: 'initSession',
          outputId: output.outputId,
        );
        _outputErrors[output.outputId] = converted;
        if (errorPolicy == MulticastOutputErrorPolicy.failFast) {
          await _rollbackOutputs(
            entries: _activeOutputs.entries.toList(),
            requestId: session.requestId,
            stage: 'initSession',
            failingOutputId: output.outputId,
          );
          _clearSession();
          throw TtsOutputFailure(outputId: output.outputId, error: converted);
        }
      }
    }

    _ensureAtLeastOneOutput(requestId: session.requestId);
  }

  @override
  Future<void> consumeChunk(TtsChunk chunk) async {
    final session = _session;
    if (session == null) {
      throw StateError('MulticastOutput session is not initialized.');
    }
    if (chunk.requestId != session.requestId) {
      throw StateError('Chunk requestId does not match active session.');
    }

    for (final entry in _activeOutputs.entries.toList()) {
      try {
        await entry.value.consumeChunk(chunk);
      } catch (error) {
        final converted = _toOutputError(
          error,
          requestId: session.requestId,
          stage: 'consumeChunk',
          outputId: entry.key,
        );
        _outputErrors[entry.key] = converted;
        _activeOutputs.remove(entry.key);
        if (errorPolicy == MulticastOutputErrorPolicy.failFast) {
          await _rollbackOutputs(
            entries: _activeOutputs.entries.toList(),
            requestId: session.requestId,
            stage: 'consumeChunk',
            failingOutputId: entry.key,
          );
          _clearSession();
          throw TtsOutputFailure(outputId: entry.key, error: converted);
        }
      }
    }

    _ensureAtLeastOneOutput(requestId: session.requestId);
  }

  @override
  Future<AudioArtifact> finalizeSession() async {
    final session = _session;
    if (session == null) {
      throw StateError('MulticastOutput session is not initialized.');
    }

    final artifacts = <String, AudioArtifact>{};
    for (final entry in _activeOutputs.entries.toList()) {
      try {
        final artifact = await entry.value.finalizeSession();
        artifacts[entry.key] = artifact;
      } catch (error) {
        final converted = _toOutputError(
          error,
          requestId: session.requestId,
          stage: 'finalizeSession',
          outputId: entry.key,
        );
        _outputErrors[entry.key] = converted;
        _activeOutputs.remove(entry.key);
        if (errorPolicy == MulticastOutputErrorPolicy.failFast) {
          await _rollbackOutputs(
            entries: _activeOutputs.entries.toList(),
            requestId: session.requestId,
            stage: 'finalizeSession',
            failingOutputId: entry.key,
          );
          _clearSession();
          throw TtsOutputFailure(outputId: entry.key, error: converted);
        }
      }
    }

    if (artifacts.isEmpty) {
      final first = _outputErrors.entries.first;
      _clearSession();
      throw TtsOutputFailure(outputId: first.key, error: first.value);
    }

    final artifact = MulticastAudioArtifact(
      requestId: session.requestId,
      audioSpec: session.audioSpec,
      artifacts: artifacts,
      outputErrors: _outputErrors,
    );
    _clearSession();
    return artifact;
  }

  @override
  Future<void> onCancelSession(SynthesisControl control) async {
    final requestId = _session?.requestId;
    final activeEntries = _activeOutputs.entries.toList();
    for (final entry in activeEntries) {
      try {
        await entry.value.onCancelSession(control);
      } catch (error) {
        final requestId = _session?.requestId;
        final converted = _toOutputError(
          error,
          requestId: requestId,
          stage: 'onCancelSession',
          outputId: entry.key,
        );
        _outputErrors[entry.key] = converted;
        if (errorPolicy == MulticastOutputErrorPolicy.failFast) {
          _clearSession();
          throw TtsOutputFailure(outputId: entry.key, error: converted);
        }
      }
    }
    if (requestId != null) {
      _playbackControlsByRequest.remove(requestId);
    }
    _clearSession();
  }

  @override
  bool hasActivePlayback(String requestId) {
    final controls = _playbackControlsByRequest[requestId];
    return controls != null && controls.isNotEmpty;
  }

  @override
  Future<void> pausePlayback(String requestId) {
    return _controlPlayback(
      requestId,
      (output) => output.pausePlayback(requestId),
    );
  }

  @override
  Future<void> resumePlayback(String requestId) {
    return _controlPlayback(
      requestId,
      (output) => output.resumePlayback(requestId),
    );
  }

  @override
  Future<void> stopPlayback(String requestId) async {
    await _controlPlayback(
      requestId,
      (output) => output.stopPlayback(requestId),
    );
    _playbackControlsByRequest.remove(requestId);
  }

  @override
  Future<void> dispose() async {
    TtsOutputFailure? firstFailure;
    for (final output in _outputs) {
      try {
        await output.dispose();
      } catch (error) {
        final converted = _toOutputError(
          error,
          requestId: _session?.requestId,
          stage: 'dispose',
          outputId: output.outputId,
        );
        _outputErrors[output.outputId] = converted;
        firstFailure ??= TtsOutputFailure(
          outputId: output.outputId,
          error: converted,
        );
      }
    }
    _clearSession();
    _playbackControlsByRequest.clear();
    for (final subscription in _playbackCompletedSubscriptions) {
      await subscription.cancel();
    }
    for (final subscription in _playbackFailedSubscriptions) {
      await subscription.cancel();
    }
    await _playbackCompletedController.close();
    await _playbackFailedController.close();
    if (firstFailure != null &&
        errorPolicy == MulticastOutputErrorPolicy.failFast) {
      throw firstFailure;
    }
  }

  TtsError _toOutputError(
    Object error, {
    required String outputId,
    required String stage,
    String? requestId,
  }) {
    if (error is TtsOutputFailure) {
      return error.error;
    }
    if (error is TtsError) {
      return TtsError(
        code: error.code,
        message: error.message,
        requestId: error.requestId ?? requestId,
        cause: error.cause,
      );
    }
    return TtsError(
      code: TtsErrorCode.outputWriteFailed,
      message: 'Output "$outputId" failed during $stage.',
      requestId: requestId,
      cause: error,
    );
  }

  void _ensureAtLeastOneOutput({required String requestId}) {
    if (_activeOutputs.isNotEmpty) {
      return;
    }

    final first = _outputErrors.entries.first;
    throw TtsOutputFailure(outputId: first.key, error: first.value);
  }

  void _clearSession() {
    _session = null;
    _activeOutputs.clear();
  }

  Future<void> _controlPlayback(
    String requestId,
    Future<void> Function(PlaybackControllableOutput output) operation,
  ) async {
    final controls = _playbackControlsByRequest[requestId];
    if (controls == null || controls.isEmpty) {
      throw StateError('No active playback for "$requestId".');
    }
    for (final output in controls.toList()) {
      await operation(output);
    }
  }

  void _forwardPlaybackCompleted(
    TtsOutput source,
    TtsOutputPlaybackCompletedEvent event,
  ) {
    _removePlaybackControl(source, event.requestId);
    _playbackCompletedController.add(event);
  }

  void _forwardPlaybackFailed(
    TtsOutput source,
    TtsOutputPlaybackFailedEvent event,
  ) {
    _removePlaybackControl(source, event.requestId);
    _playbackFailedController.add(event);
  }

  void _removePlaybackControl(TtsOutput source, String requestId) {
    final PlaybackControllableOutput? playbackControl =
        source is PlaybackControllableOutput
        ? source as PlaybackControllableOutput
        : null;
    if (playbackControl == null) {
      return;
    }
    final controls = _playbackControlsByRequest[requestId];
    if (controls == null) {
      return;
    }
    controls.remove(playbackControl);
    if (controls.isEmpty) {
      _playbackControlsByRequest.remove(requestId);
    }
  }

  Future<void> _rollbackOutputs({
    required List<MapEntry<String, TtsOutput>> entries,
    required String? requestId,
    required String stage,
    required String failingOutputId,
  }) async {
    final rollbackControl = SynthesisControl()
      ..cancel(
        CancelReason.stopCurrent,
        message:
            'Rollback after failFast failure in $stage ($failingOutputId).',
      );

    for (final entry in entries) {
      try {
        await entry.value.onCancelSession(rollbackControl);
      } catch (error) {
        final converted = _toOutputError(
          error,
          requestId: requestId,
          stage: '$stage.rollback.onCancelSession',
          outputId: entry.key,
        );
        _outputErrors[entry.key] = converted;
      } finally {
        _activeOutputs.remove(entry.key);
      }
    }
  }
}
