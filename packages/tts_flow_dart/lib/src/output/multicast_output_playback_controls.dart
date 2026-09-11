part of 'multicast_output.dart';

/// Tracks controllable child playbacks independently of write-session state.
final class _MulticastPlaybackControls {
  final Map<String, Set<PlaybackControllableOutput>> _byRequest =
      <String, Set<PlaybackControllableOutput>>{};

  void register(String requestKey, PlaybackControllableOutput output) {
    _byRequest
        .putIfAbsent(requestKey, () => <PlaybackControllableOutput>{})
        .add(output);
  }

  bool has(String requestKey) {
    final controls = _byRequest[requestKey];
    return controls != null && controls.isNotEmpty;
  }

  Future<void> pause(String requestKey) {
    return _control(requestKey, (output) => output.pausePlayback(requestKey));
  }

  Future<void> resume(String requestKey) {
    return _control(requestKey, (output) => output.resumePlayback(requestKey));
  }

  Future<void> stop(String requestKey) async {
    await _control(requestKey, (output) => output.stopPlayback(requestKey));
    removeRequest(requestKey);
  }

  void remove(String requestKey, PlaybackControllableOutput output) {
    final controls = _byRequest[requestKey];
    if (controls == null) {
      return;
    }
    controls.remove(output);
    if (controls.isEmpty) {
      _byRequest.remove(requestKey);
    }
  }

  void removeRequest(String requestKey) {
    _byRequest.remove(requestKey);
  }

  void clear() {
    _byRequest.clear();
  }

  Future<void> _control(
    String requestKey,
    Future<void> Function(PlaybackControllableOutput output) operation,
  ) async {
    final controls = _byRequest[requestKey];
    if (controls == null || controls.isEmpty) {
      throw StateError('No active playback for "$requestKey".');
    }
    for (final output in controls.toList()) {
      await operation(output);
    }
  }
}
