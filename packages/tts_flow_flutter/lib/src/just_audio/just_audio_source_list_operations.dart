part of 'just_audio_backend.dart';

/// Source-list mutations and player-start helpers for [JustAudioBackend].
///
/// Every caller already executes through the backend's serialized
/// player-operation queue; these helpers must not introduce a second queue.
extension _JustAudioSourceListOperations on JustAudioBackend {
  Future<ChunkAudioSource> _createSegment(
    _PlaybackSession session, {
    required List<int> initialBytes,
  }) async {
    final sourceIndex = session.nextIndex;
    // 原生播放器可能在 addAudioSource 返回前预加载，必须先填好字节。
    final source = ChunkAudioSource(
      audioSpec: session.audioSpec,
      playbackId: session.playbackId,
      index: sourceIndex,
      requestKey: session.requestKey,
      isTerminalSegment: session.isFinalized,
      onStarted: () {
        if (_disposeRequested) {
          return;
        }
        _playbackSourceStartedController.add(
          JustAudioPlaybackSourceStartedEvent(
            playbackId: session.playbackId,
            requestKey: session.requestKey,
            sourceIndex: sourceIndex,
            timestamp: DateTime.now().toUtc(),
          ),
        );
      },
    )..addChunk(initialBytes);
    session.nextIndex++;

    session.tailSource = source;
    await _player.addAudioSource(source);
    _logger.fine('Added new segment for ${session.playbackId}');
    return source;
  }

  Future<void> _ensurePlaybackRunning() async {
    if (_player.audioSources.isEmpty) {
      return;
    }

    if (!_player.playing) {
      if (_player.processingState == ProcessingState.completed &&
          _player.currentIndex != null &&
          _player.currentIndex! < _player.audioSources.length - 1) {
        await _seekToNextSource();
      } else if (_player.currentIndex == null) {
        await _seekToSource(0);
      }
      _startPlayerInBackground();
      return;
    }

    if (_player.processingState == ProcessingState.completed &&
        _player.currentIndex != null &&
        _player.currentIndex! < _player.audioSources.length - 1) {
      await _seekToNextSource();
      _startPlayerInBackground();
    }
  }

  bool get _usesMediaKit =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.windows ||
          defaultTargetPlatform == TargetPlatform.linux);

  Future<void> _seekToNextSource() => _usesMediaKit
      ? _seekToSource(_player.currentIndex! + 1)
      : _player.seekToNext();

  Future<void> _seekToSource(int index) {
    // media_kit 的 jump 已从目标片段开头播放，null 避免再发一次 seek(0)。
    // 2.1.0 适配器会把短片段的 seek 延后到后续长片段，并重置 EOF 状态。
    return _player.seek(_usesMediaKit ? null : Duration.zero, index: index);
  }

  _SourceRange? _findRangeForPlayback(String playbackId) {
    var seen = false;
    var gapStarted = false;
    int? start;
    var endExclusive = 0;

    for (var index = 0; index < _player.audioSources.length; index++) {
      final source = _player.audioSources[index];
      if (source is! ChunkAudioSource) {
        throw StateError(
          'Unexpected audio source type in playlist: ${source.runtimeType}',
        );
      }

      if (source.playbackId == playbackId) {
        if (gapStarted) {
          throw StateError('Playback segments must be contiguous: $playbackId');
        }
        seen = true;
        start ??= index;
        endExclusive = index + 1;
      } else if (seen) {
        gapStarted = true;
      }
    }

    return start == null
        ? null
        : _SourceRange(start: start, endExclusive: endExclusive);
  }

  Future<void> _resumeAfterRemoval(int removedStart) async {
    if (_player.audioSources.isEmpty) {
      await _player.stop();
      return;
    }

    final nextIndex = removedStart >= _player.audioSources.length
        ? _player.audioSources.length - 1
        : removedStart;
    await _player.stop();
    await _seekToSource(nextIndex);
    _startPlayerInBackground();
  }

  /// Starts just_audio without blocking source-list mutations.
  ///
  /// [AudioPlayer.play] completes only when playback ends, pauses, or stops.
  /// Awaiting it in the serialized operation queue would prevent subsequent
  /// chunks from being appended while the first source is playing.
  void _startPlayerInBackground() {
    unawaited(_awaitPlayerStart());
  }

  Future<void> _awaitPlayerStart() async {
    try {
      await _player.play();
    } on Object catch (error, stackTrace) {
      // Native decode errors are correlated to a session by errorStream. This
      // branch prevents an unhandled play Future from escaping the queue while
      // retaining a diagnostic for errors that do not reach that stream.
      _logger.warning('just_audio play invocation failed.', error, stackTrace);
    }
  }
}
