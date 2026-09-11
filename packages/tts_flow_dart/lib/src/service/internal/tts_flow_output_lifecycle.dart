part of '../tts_flow.dart';

/// Owns output initialization and the request-scoped resources attached to it.
///
/// Queue scheduling remains in [TtsUtteranceQueueMixin]; this mixin only keeps
/// output instances, playback controls, and event streams alive for the
/// duration required by a request.
mixin TtsFlowOutputLifecycle on TtsUtteranceQueueMixin {
  final _managedOutputs = HashSet<TtsOutput>.identity();
  final _outputInitializations = HashMap<TtsOutput, Future<void>>.identity();
  final _playbackOutputs = <String, TtsOutput>{};
  final _utteranceIdsByRequestKey = <String, String>{};
  final _requestEventControllers =
      <String, StreamController<TtsRequestEvent>>{};

  @override
  @protected
  String? utteranceIdForRequestKey(String requestKey) =>
      _utteranceIdsByRequestKey[requestKey];

  @override
  @protected
  void onRequestEventEmitted(TtsRequestEvent event) {
    _requestEventControllers[event.requestKey]?.add(event);
  }

  bool _hasActivePlayback(String requestKey) {
    final output = _playbackOutputs[requestKey];
    final PlaybackControllableOutput? controllableOutput =
        output is PlaybackControllableOutput
        ? output as PlaybackControllableOutput
        : null;
    return controllableOutput?.hasActivePlayback(requestKey) ?? false;
  }

  /// Initializes [output] at most once for this flow.
  ///
  /// `TtsFlow` owns every output passed to it, including request-level output
  /// overrides, and disposes those outputs when the flow is disposed.
  @override
  @protected
  Future<void> ensureOutputInitialized(TtsOutput output) async {
    _managedOutputs.add(output);

    final existingInitialization = _outputInitializations[output];
    if (existingInitialization != null) {
      await existingInitialization;
      return;
    }

    final initialization = Future<void>.sync(output.init);
    _outputInitializations[output] = initialization;
    try {
      await initialization;
    } catch (_) {
      if (identical(_outputInitializations[output], initialization)) {
        _outputInitializations.remove(output);
      }
      rethrow;
    }
  }

  @override
  @protected
  void registerPlaybackControl(String requestKey, TtsOutput output) {
    if (output is PlaybackControllableOutput) {
      _playbackOutputs[requestKey] = output;
    }
  }

  @override
  @protected
  void unregisterPlaybackControl(String requestKey) {
    _playbackOutputs.remove(requestKey);
  }

  @override
  @protected
  bool hasPlaybackControl(String requestKey) =>
      _playbackOutputs.containsKey(requestKey);

  @override
  @protected
  int get outstandingPlaybackRequestCount => _playbackOutputs.length;

  @override
  @protected
  void releaseRequestIdentity(String requestKey) {
    _utteranceIdsByRequestKey.remove(requestKey);
    final controller = _requestEventControllers.remove(requestKey);
    if (controller != null) {
      unawaited(controller.close());
    }
  }

  Future<void> _disposeManagedOutputs() async {
    Object? firstError;
    StackTrace? firstStackTrace;

    for (final output in _managedOutputs) {
      try {
        await output.dispose();
      } catch (error, stackTrace) {
        firstError ??= error;
        firstStackTrace ??= stackTrace;
      }
    }
    _managedOutputs.clear();
    _outputInitializations.clear();

    if (firstError != null) {
      Error.throwWithStackTrace(firstError, firstStackTrace!);
    }
  }

  Future<void> _awaitActiveRequestShutdown({Duration? timeout}) async {
    const pollInterval = Duration(milliseconds: 10);
    final deadline = timeout == null ? null : DateTime.now().add(timeout);

    while (state.activeControl != null &&
        (deadline == null || DateTime.now().isBefore(deadline))) {
      await Future<void>.delayed(pollInterval);
    }
  }
}
