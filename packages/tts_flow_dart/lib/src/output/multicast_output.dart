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
          requestKey: null,
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
                session.requestKey,
                () => <PlaybackControllableOutput>{},
              )
              .add(playbackOutput);
        }
      } catch (error) {
        final converted = _toOutputError(
          error,
          requestKey: session.requestKey,
          stage: 'initSession',
          outputId: output.outputId,
        );
        _outputErrors[output.outputId] = converted;
        if (errorPolicy == MulticastOutputErrorPolicy.failFast) {
          await _rollbackOutputs(
            entries: _activeOutputs.entries.toList(),
            requestKey: session.requestKey,
            stage: 'initSession',
            failingOutputId: output.outputId,
          );
          _clearSession();
          throw TtsOutputFailure(outputId: output.outputId, error: converted);
        }
      }
    }

    _ensureAtLeastOneOutput(requestKey: session.requestKey);
  }

  @override
  Future<void> consumeChunk(TtsChunk chunk) async {
    final session = _session;
    if (session == null) {
      throw StateError('MulticastOutput session is not initialized.');
    }
    if (chunk.requestKey != session.requestKey) {
      throw StateError('Chunk requestKey does not match active session.');
    }

    for (final entry in _activeOutputs.entries.toList()) {
      try {
        await entry.value.consumeChunk(chunk);
      } catch (error) {
        final converted = _toOutputError(
          error,
          requestKey: session.requestKey,
          stage: 'consumeChunk',
          outputId: entry.key,
        );
        _outputErrors[entry.key] = converted;
        _activeOutputs.remove(entry.key);
        if (errorPolicy == MulticastOutputErrorPolicy.failFast) {
          await _rollbackOutputs(
            entries: _activeOutputs.entries.toList(),
            requestKey: session.requestKey,
            stage: 'consumeChunk',
            failingOutputId: entry.key,
          );
          _clearSession();
          throw TtsOutputFailure(outputId: entry.key, error: converted);
        }
      }
    }

    _ensureAtLeastOneOutput(requestKey: session.requestKey);
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
          requestKey: session.requestKey,
          stage: 'finalizeSession',
          outputId: entry.key,
        );
        _outputErrors[entry.key] = converted;
        _activeOutputs.remove(entry.key);
        if (errorPolicy == MulticastOutputErrorPolicy.failFast) {
          await _rollbackOutputs(
            entries: _activeOutputs.entries.toList(),
            requestKey: session.requestKey,
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
      requestKey: session.requestKey,
      audioSpec: session.audioSpec,
      artifacts: artifacts,
      outputErrors: _outputErrors,
    );
    _clearSession();
    return artifact;
  }

  @override
  Future<void> onCancelSession(SynthesisControl control) async {
    final requestKey = _session?.requestKey;
    final activeEntries = _activeOutputs.entries.toList();
    for (final entry in activeEntries) {
      try {
        await entry.value.onCancelSession(control);
      } catch (error) {
        final requestKey = _session?.requestKey;
        final converted = _toOutputError(
          error,
          requestKey: requestKey,
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
    if (requestKey != null) {
      _playbackControlsByRequest.remove(requestKey);
    }
    _clearSession();
  }

  @override
  bool hasActivePlayback(String requestKey) {
    final controls = _playbackControlsByRequest[requestKey];
    return controls != null && controls.isNotEmpty;
  }

  @override
  Future<void> pausePlayback(String requestKey) {
    return _controlPlayback(
      requestKey,
      (output) => output.pausePlayback(requestKey),
    );
  }

  @override
  Future<void> resumePlayback(String requestKey) {
    return _controlPlayback(
      requestKey,
      (output) => output.resumePlayback(requestKey),
    );
  }

  @override
  Future<void> stopPlayback(String requestKey) async {
    await _controlPlayback(
      requestKey,
      (output) => output.stopPlayback(requestKey),
    );
    _playbackControlsByRequest.remove(requestKey);
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
          requestKey: _session?.requestKey,
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
    String? requestKey,
  }) {
    if (error is TtsOutputFailure) {
      return error.error;
    }
    if (error is TtsError) {
      return TtsError(
        code: error.code,
        message: error.message,
        requestKey: error.requestKey ?? requestKey,
        cause: error.cause,
      );
    }
    return TtsError(
      code: TtsErrorCode.outputWriteFailed,
      message: 'Output "$outputId" failed during $stage.',
      requestKey: requestKey,
      cause: error,
    );
  }

  void _ensureAtLeastOneOutput({required String requestKey}) {
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
    String requestKey,
    Future<void> Function(PlaybackControllableOutput output) operation,
  ) async {
    final controls = _playbackControlsByRequest[requestKey];
    if (controls == null || controls.isEmpty) {
      throw StateError('No active playback for "$requestKey".');
    }
    for (final output in controls.toList()) {
      await operation(output);
    }
  }

  void _forwardPlaybackCompleted(
    TtsOutput source,
    TtsOutputPlaybackCompletedEvent event,
  ) {
    _removePlaybackControl(source, event.requestKey);
    _playbackCompletedController.add(event);
  }

  void _forwardPlaybackFailed(
    TtsOutput source,
    TtsOutputPlaybackFailedEvent event,
  ) {
    _removePlaybackControl(source, event.requestKey);
    _playbackFailedController.add(event);
  }

  void _removePlaybackControl(TtsOutput source, String requestKey) {
    final PlaybackControllableOutput? playbackControl =
        source is PlaybackControllableOutput
        ? source as PlaybackControllableOutput
        : null;
    if (playbackControl == null) {
      return;
    }
    final controls = _playbackControlsByRequest[requestKey];
    if (controls == null) {
      return;
    }
    controls.remove(playbackControl);
    if (controls.isEmpty) {
      _playbackControlsByRequest.remove(requestKey);
    }
  }

  Future<void> _rollbackOutputs({
    required List<MapEntry<String, TtsOutput>> entries,
    required String? requestKey,
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
          requestKey: requestKey,
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
