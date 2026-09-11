import 'dart:async';

import 'package:tts_flow_dart/src/core/audio_artifact.dart';
import 'package:tts_flow_dart/src/core/audio_capability.dart';
import 'package:tts_flow_dart/src/core/synthesis_control.dart';
import 'package:tts_flow_dart/src/core/tts_chunk.dart';
import 'package:tts_flow_dart/src/core/tts_errors.dart';
import 'package:tts_flow_dart/src/core/tts_output.dart';
import 'package:tts_flow_dart/src/core/tts_output_write_context.dart';
import 'package:tts_flow_dart/src/core/tts_policy.dart';
import 'package:tts_flow_dart/src/output/capability_intersection.dart';

part 'multicast_output_playback_controls.dart';

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

  TtsOutputWriteContext? _writeContext;
  final Map<String, TtsOutput> _activeOutputs = <String, TtsOutput>{};
  final Map<String, TtsError> _outputErrors = <String, TtsError>{};
  final _playbackControls = _MulticastPlaybackControls();

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
  Future<void> startWrite(TtsOutputWriteContext writeContext) async {
    _writeContext = writeContext;
    _activeOutputs.clear();
    _outputErrors.clear();

    for (final output in _outputs) {
      try {
        await output.startWrite(writeContext);
        _activeOutputs[output.outputId] = output;
        if (output case final PlaybackControllableOutput playbackOutput) {
          _playbackControls.register(writeContext.requestKey, playbackOutput);
        }
      } catch (error) {
        final converted = _toOutputError(
          error,
          requestKey: writeContext.requestKey,
          stage: 'startWrite',
          outputId: output.outputId,
        );
        _outputErrors[output.outputId] = converted;
        if (errorPolicy == MulticastOutputErrorPolicy.failFast) {
          await _rollbackOutputs(
            entries: _activeOutputs.entries.toList(),
            requestKey: writeContext.requestKey,
            stage: 'startWrite',
            failingOutputId: output.outputId,
          );
          _clearSession();
          throw TtsOutputFailure(outputId: output.outputId, error: converted);
        }
      }
    }

    _ensureAtLeastOneOutput(requestKey: writeContext.requestKey);
  }

  @override
  Future<void> writeChunk(TtsChunk chunk) async {
    final writeContext = _writeContext;
    if (writeContext == null) {
      throw StateError('MulticastOutput write has not started.');
    }
    if (chunk.requestKey != writeContext.requestKey) {
      throw StateError('Chunk requestKey does not match active write.');
    }

    for (final entry in _activeOutputs.entries.toList()) {
      try {
        await entry.value.writeChunk(chunk);
      } catch (error) {
        final converted = _toOutputError(
          error,
          requestKey: writeContext.requestKey,
          stage: 'writeChunk',
          outputId: entry.key,
        );
        _outputErrors[entry.key] = converted;
        _activeOutputs.remove(entry.key);
        if (errorPolicy == MulticastOutputErrorPolicy.failFast) {
          await _rollbackOutputs(
            entries: _activeOutputs.entries.toList(),
            requestKey: writeContext.requestKey,
            stage: 'writeChunk',
            failingOutputId: entry.key,
          );
          _clearSession();
          throw TtsOutputFailure(outputId: entry.key, error: converted);
        }
      }
    }

    _ensureAtLeastOneOutput(requestKey: writeContext.requestKey);
  }

  @override
  Future<AudioArtifact> finishWrite() async {
    final writeContext = _writeContext;
    if (writeContext == null) {
      throw StateError('MulticastOutput write has not started.');
    }

    final artifacts = <String, AudioArtifact>{};
    for (final entry in _activeOutputs.entries.toList()) {
      try {
        final artifact = await entry.value.finishWrite();
        artifacts[entry.key] = artifact;
      } catch (error) {
        final converted = _toOutputError(
          error,
          requestKey: writeContext.requestKey,
          stage: 'finishWrite',
          outputId: entry.key,
        );
        _outputErrors[entry.key] = converted;
        _activeOutputs.remove(entry.key);
        if (errorPolicy == MulticastOutputErrorPolicy.failFast) {
          await _rollbackOutputs(
            entries: _activeOutputs.entries.toList(),
            requestKey: writeContext.requestKey,
            stage: 'finishWrite',
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
      requestKey: writeContext.requestKey,
      audioSpec: writeContext.audioSpec,
      artifacts: artifacts,
      outputErrors: _outputErrors,
    );
    _clearSession();
    return artifact;
  }

  @override
  Future<void> cancelWrite(SynthesisControl control) async {
    final requestKey = _writeContext?.requestKey;
    final activeEntries = _activeOutputs.entries.toList();
    for (final entry in activeEntries) {
      try {
        await entry.value.cancelWrite(control);
      } catch (error) {
        final requestKey = _writeContext?.requestKey;
        final converted = _toOutputError(
          error,
          requestKey: requestKey,
          stage: 'cancelWrite',
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
      _playbackControls.removeRequest(requestKey);
    }
    _clearSession();
  }

  @override
  bool hasActivePlayback(String requestKey) =>
      _playbackControls.has(requestKey);

  @override
  Future<void> pausePlayback(String requestKey) =>
      _playbackControls.pause(requestKey);

  @override
  Future<void> resumePlayback(String requestKey) =>
      _playbackControls.resume(requestKey);

  @override
  Future<void> stopPlayback(String requestKey) =>
      _playbackControls.stop(requestKey);

  @override
  Future<void> dispose() async {
    TtsOutputFailure? firstFailure;
    for (final output in _outputs) {
      try {
        await output.dispose();
      } catch (error) {
        final converted = _toOutputError(
          error,
          requestKey: _writeContext?.requestKey,
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
    _playbackControls.clear();
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
    _writeContext = null;
    _activeOutputs.clear();
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
    _playbackControls.remove(requestKey, playbackControl);
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
        await entry.value.cancelWrite(rollbackControl);
      } catch (error) {
        final converted = _toOutputError(
          error,
          requestKey: requestKey,
          stage: '$stage.rollback.cancelWrite',
          outputId: entry.key,
        );
        _outputErrors[entry.key] = converted;
      } finally {
        _activeOutputs.remove(entry.key);
      }
    }
  }
}
