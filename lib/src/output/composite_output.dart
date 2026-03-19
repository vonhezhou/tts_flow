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
final class CompositeOutput implements TtsOutput {
  CompositeOutput({
    required List<TtsOutput> outputs,
    this.outputId = 'composite-output',
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
  Set<TtsAudioFormat> get acceptedFormats {
    var current = _outputs.first.acceptedFormats.toSet();
    for (final output in _outputs.skip(1)) {
      current = current.intersection(output.acceptedFormats);
    }
    return current;
  }

  @override
  Future<void> initSession(TtsOutputSession session) async {
    _session = session;
    _activeOutputs
      ..clear()
      ..addEntries(_outputs.map((output) => MapEntry(output.outputId, output)));
    _outputErrors.clear();

    for (final output in _outputs) {
      try {
        await output.initSession(session);
      } catch (error) {
        final converted = _toOutputError(
          error,
          requestId: session.requestId,
          stage: 'initSession',
          outputId: output.outputId,
        );
        _outputErrors[output.outputId] = converted;
        _activeOutputs.remove(output.outputId);
        if (errorPolicy == CompositeOutputErrorPolicy.failFast) {
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
          throw TtsOutputFailure(outputId: entry.key, error: converted);
        }
      }
    }

    _ensureAtLeastOneOutput(requestId: session.requestId);
  }

  @override
  Future<TtsOutputArtifact> finalizeSession() async {
    final session = _session;
    if (session == null) {
      throw StateError('CompositeOutput session is not initialized.');
    }

    final artifacts = <String, TtsOutputArtifact>{};
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

    final artifact = CompositeOutputArtifact(
      requestId: session.requestId,
      resolvedFormat: session.resolvedFormat,
      artifacts: artifacts,
      outputErrors: _outputErrors,
    );
    _clearSession();
    return artifact;
  }

  @override
  Future<void> onPause() async {
    for (final entry in _activeOutputs.entries.toList()) {
      try {
        await entry.value.onPause();
      } catch (error) {
        final converted = _toOutputError(
          error,
          requestId: _session?.requestId,
          stage: 'onPause',
          outputId: entry.key,
        );
        _outputErrors[entry.key] = converted;
        _activeOutputs.remove(entry.key);
        if (errorPolicy == CompositeOutputErrorPolicy.failFast) {
          throw TtsOutputFailure(outputId: entry.key, error: converted);
        }
      }
    }
  }

  @override
  Future<void> onResume() async {
    for (final entry in _activeOutputs.entries.toList()) {
      try {
        await entry.value.onResume();
      } catch (error) {
        final converted = _toOutputError(
          error,
          requestId: _session?.requestId,
          stage: 'onResume',
          outputId: entry.key,
        );
        _outputErrors[entry.key] = converted;
        _activeOutputs.remove(entry.key);
        if (errorPolicy == CompositeOutputErrorPolicy.failFast) {
          throw TtsOutputFailure(outputId: entry.key, error: converted);
        }
      }
    }
  }

  @override
  Future<void> onStop(String reason) async {
    final activeEntries = _activeOutputs.entries.toList();
    for (final entry in activeEntries) {
      try {
        await entry.value.onStop(reason);
      } catch (error) {
        final requestId = _session?.requestId;
        final converted = _toOutputError(
          error,
          requestId: requestId,
          stage: 'onStop',
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
}
