import '../core/tts_contracts.dart';
import '../core/tts_errors.dart';
import '../core/tts_models.dart';

enum CompositeOutputErrorPolicy {
  /// If any individual output fails,
  /// the entire composite output fails immediately.
  failFast,

  /// If any individual output fails,
  /// the error is recorded but the composite output
  /// continues operating with the remaining outputs.
  bestEffort,
}

/// A TtsOutput that wraps multiple child outputs
/// and forwards all calls to them.
final class MulticastOutput implements TtsOutput {
  MulticastOutput({
    required List<TtsOutput> outputs,
    this.outputId = 'multicast-output',
    this.errorPolicy = CompositeOutputErrorPolicy.bestEffort,
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

  final CompositeOutputErrorPolicy errorPolicy;

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
        if (errorPolicy == CompositeOutputErrorPolicy.failFast) {
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
      throw StateError('CompositeOutput session is not initialized.');
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
        if (errorPolicy == CompositeOutputErrorPolicy.failFast) {
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
      throw StateError('CompositeOutput session is not initialized.');
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
        if (errorPolicy == CompositeOutputErrorPolicy.failFast) {
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

    final artifact = CompositeAudioArtifact(
      requestId: session.requestId,
      audioSpec: session.audioSpec,
      artifacts: artifacts,
      outputErrors: _outputErrors,
    );
    _clearSession();
    return artifact;
  }

  @override
  Future<void> onCancel(SynthesisControl control) async {
    final activeEntries = _activeOutputs.entries.toList();
    for (final entry in activeEntries) {
      try {
        await entry.value.onCancel(control);
      } catch (error) {
        final requestId = _session?.requestId;
        final converted = _toOutputError(
          error,
          requestId: requestId,
          stage: 'onCancel',
          outputId: entry.key,
        );
        _outputErrors[entry.key] = converted;
        if (errorPolicy == CompositeOutputErrorPolicy.failFast) {
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
        firstFailure ??=
            TtsOutputFailure(outputId: output.outputId, error: converted);
      }
    }
    _clearSession();
    if (firstFailure != null &&
        errorPolicy == CompositeOutputErrorPolicy.failFast) {
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
        await entry.value.onCancel(rollbackControl);
      } catch (error) {
        final converted = _toOutputError(
          error,
          requestId: requestId,
          stage: '$stage.rollback.onCancel',
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
        result.add(SimpleFormatCapability(format: leftCapability.format));
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
      leftDiscrete: left.sampleRatesHz,
      leftMin: left.minSampleRateHz,
      leftMax: left.maxSampleRateHz,
      rightDiscrete: right.sampleRatesHz,
      rightMin: right.minSampleRateHz,
      rightMax: right.maxSampleRateHz,
    );
    if (sampleRate == null) {
      return null;
    }

    final bitDepth = _intersectIntConstraint(
      leftDiscrete: left.bitsPerSample,
      leftMin: left.minBitsPerSample,
      leftMax: left.maxBitsPerSample,
      rightDiscrete: right.bitsPerSample,
      rightMin: right.minBitsPerSample,
      rightMax: right.maxBitsPerSample,
    );
    if (bitDepth == null) {
      return null;
    }

    final channels = _intersectIntConstraint(
      leftDiscrete: left.channels,
      leftMin: left.minChannels,
      leftMax: left.maxChannels,
      rightDiscrete: right.channels,
      rightMin: right.minChannels,
      rightMax: right.maxChannels,
    );
    if (channels == null) {
      return null;
    }

    final encodings = left.encodings.intersection(right.encodings);
    if (encodings.isEmpty) {
      return null;
    }

    return PcmCapability(
      sampleRatesHz: sampleRate.discrete,
      minSampleRateHz: sampleRate.min,
      maxSampleRateHz: sampleRate.max,
      bitsPerSample: bitDepth.discrete,
      minBitsPerSample: bitDepth.min,
      maxBitsPerSample: bitDepth.max,
      channels: channels.discrete,
      minChannels: channels.min,
      maxChannels: channels.max,
      encodings: encodings,
    );
  }

  _IntConstraint? _intersectIntConstraint({
    required Set<int> leftDiscrete,
    required int? leftMin,
    required int? leftMax,
    required Set<int> rightDiscrete,
    required int? rightMin,
    required int? rightMax,
  }) {
    final hasLeftRange = leftMin != null && leftMax != null;
    final hasRightRange = rightMin != null && rightMax != null;

    final min = hasLeftRange && hasRightRange
        ? (leftMin > rightMin ? leftMin : rightMin)
        : (hasLeftRange ? leftMin : (hasRightRange ? rightMin : null));
    final max = hasLeftRange && hasRightRange
        ? (leftMax < rightMax ? leftMax : rightMax)
        : (hasLeftRange ? leftMax : (hasRightRange ? rightMax : null));

    if (min != null && max != null && min > max) {
      return null;
    }

    Set<int> discrete;
    if (leftDiscrete.isNotEmpty && rightDiscrete.isNotEmpty) {
      discrete = leftDiscrete.intersection(rightDiscrete);
    } else if (leftDiscrete.isNotEmpty) {
      discrete = leftDiscrete.toSet();
    } else if (rightDiscrete.isNotEmpty) {
      discrete = rightDiscrete.toSet();
    } else {
      discrete = <int>{};
    }

    if (discrete.isNotEmpty && min != null && max != null) {
      discrete =
          discrete.where((value) => value >= min && value <= max).toSet();
    }

    if (discrete.isEmpty && min == null && max == null) {
      return null;
    }
    if (discrete.isEmpty &&
        (leftDiscrete.isNotEmpty || rightDiscrete.isNotEmpty)) {
      return null;
    }

    return _IntConstraint(discrete: discrete, min: min, max: max);
  }
}

final class _IntConstraint {
  const _IntConstraint({
    required this.discrete,
    required this.min,
    required this.max,
  });

  final Set<int> discrete;
  final int? min;
  final int? max;
}
