import 'package:tts_flow_dart/src/core/audio_artifact.dart';
import 'package:tts_flow_dart/src/core/audio_capability.dart';
import 'package:tts_flow_dart/src/core/audio_spec.dart';
import 'package:tts_flow_dart/src/base/pcm_descriptor.dart';
import 'package:tts_flow_dart/src/core/synthesis_control.dart';
import 'package:tts_flow_dart/src/core/tts_chunk.dart';
import 'package:tts_flow_dart/src/core/tts_errors.dart';
import 'package:tts_flow_dart/src/core/tts_output.dart';
import 'package:tts_flow_dart/src/core/tts_output_session.dart';
import 'package:tts_flow_dart/src/core/tts_policy.dart';

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
final class MulticastOutput implements TtsOutput {
  MulticastOutput({
    required List<TtsOutput> outputs,
    this.outputId = 'multicast-output',
    this.errorPolicy = MulticastOutputErrorPolicy.bestEffort,
  }) : _outputs = List.unmodifiable(outputs) {
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
  }

  final List<TtsOutput> _outputs;

  @override
  final String outputId;

  final MulticastOutputErrorPolicy errorPolicy;

  TtsOutputSession? _session;
  final Map<String, TtsOutput> _activeOutputs = <String, TtsOutput>{};
  final Map<String, TtsError> _outputErrors = <String, TtsError>{};

  @override
  Set<AudioCapability> get acceptedCapabilities {
    var current = _outputs.first.acceptedCapabilities.toSet();
    for (final output in _outputs.skip(1)) {
      current = _intersectCapabilities(current, output.acceptedCapabilities);
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
    _clearSession();
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

  Set<AudioCapability> _intersectCapabilities(
    Set<AudioCapability> left,
    Set<AudioCapability> right,
  ) {
    final rightByFormat = <TtsAudioFormat, List<AudioCapability>>{};
    for (final capability in right) {
      rightByFormat
          .putIfAbsent(capability.format, () => <AudioCapability>[])
          .add(capability);
    }

    final result = <AudioCapability>{};
    for (final leftCapability in left) {
      final candidates = rightByFormat[leftCapability.format];
      if (candidates == null || candidates.isEmpty) {
        continue;
      }

      if (leftCapability.format != TtsAudioFormat.pcm) {
        result.add(_formatToCapability(leftCapability.format));
        continue;
      }

      if (leftCapability is! PcmCapability) {
        continue;
      }

      for (final rightCapability in candidates) {
        if (rightCapability is! PcmCapability) {
          continue;
        }
        final intersected = _intersectPcmCapabilities(
          leftCapability,
          rightCapability,
        );
        if (intersected != null) {
          result.add(intersected);
        }
      }
    }

    return result;
  }

  PcmCapability? _intersectPcmCapabilities(
    PcmCapability left,
    PcmCapability right,
  ) {
    final sampleRate = _intersectIntConstraint(
      leftValues: left.sampleRatesHz,
      rightValues: right.sampleRatesHz,
    );
    if (sampleRate == null || sampleRate.isEmpty) {
      return null;
    }

    final bitDepth = _intersectIntConstraint(
      leftValues: left.bitsPerSample,
      rightValues: right.bitsPerSample,
    );
    if (bitDepth == null || bitDepth.isEmpty) {
      return null;
    }

    final channels = _intersectIntConstraint(
      leftValues: left.channels,
      rightValues: right.channels,
    );
    if (channels == null || channels.isEmpty) {
      return null;
    }

    final encodings = _intersectEncodings(
      leftValues: left.encodings,
      rightValues: right.encodings,
    );
    if (encodings.isEmpty) {
      return null;
    }

    return PcmCapability(
      sampleRatesHz: sampleRate,
      bitsPerSample: bitDepth,
      channels: channels,
      encodings: encodings,
    );
  }

  Set<int>? _intersectIntConstraint({
    required Set<int>? leftValues,
    required Set<int>? rightValues,
  }) {
    if (leftValues != null && leftValues.isEmpty) {
      return const <int>{};
    }
    if (rightValues != null && rightValues.isEmpty) {
      return const <int>{};
    }

    if (leftValues == null && rightValues == null) {
      return null;
    }

    if (leftValues == null) {
      return Set<int>.from(rightValues!);
    }
    if (rightValues == null) {
      return Set<int>.from(leftValues);
    }

    return leftValues.intersection(rightValues);
  }

  Set<PcmEncoding> _intersectEncodings({
    required Set<PcmEncoding>? leftValues,
    required Set<PcmEncoding>? rightValues,
  }) {
    if (leftValues != null && leftValues.isEmpty) {
      return const <PcmEncoding>{};
    }
    if (rightValues != null && rightValues.isEmpty) {
      return const <PcmEncoding>{};
    }

    if (leftValues == null && rightValues == null) {
      return Set<PcmEncoding>.from(PcmEncoding.values);
    }
    if (leftValues == null) {
      return Set<PcmEncoding>.from(rightValues!);
    }
    if (rightValues == null) {
      return Set<PcmEncoding>.from(leftValues);
    }

    return leftValues.intersection(rightValues);
  }

  AudioCapability _formatToCapability(TtsAudioFormat format) {
    return switch (format) {
      TtsAudioFormat.pcm => PcmCapability(),
      TtsAudioFormat.mp3 => const Mp3Capability(),
      TtsAudioFormat.opus => const OpusCapability(),
      TtsAudioFormat.aac => const AacCapability(),
    };
  }
}
