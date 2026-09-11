part of 'just_audio_backend.dart';

/// Translates native source duration and position callbacks into request-level
/// playback timeline events.
final class _JustAudioPlaybackTimeline {
  const _JustAudioPlaybackTimeline({
    required this.sessions,
    required this.positionController,
  });

  final Map<String, _PlaybackSession> sessions;
  final StreamController<TtsPlaybackPositionEvent> positionController;

  void onDurationChanged(AudioSource? currentSource, Duration? duration) {
    if (duration == null || currentSource is! ChunkAudioSource) {
      return;
    }

    final session = sessions[currentSource.playbackId];
    if (session == null) {
      return;
    }

    session.addOrUpdateSourceDuration(currentSource.index, duration);
    currentSource.playbackOffset = session.calcDurationOffset(
      currentSource.index,
    );
    _logger.fine(
      'onDuration: '
      '${currentSource.requestKey},${currentSource.index} '
      '$duration, ${currentSource.playbackOffset}',
    );
  }

  void onPositionChanged(AudioSource? currentSource, Duration position) {
    if (currentSource is! ChunkAudioSource) {
      return;
    }

    final session = sessions[currentSource.playbackId];
    if (session == null) {
      return;
    }

    if (currentSource.index != 0 &&
        currentSource.playbackOffset == Duration.zero) {
      currentSource.playbackOffset = session.calcDurationOffset(
        currentSource.index,
      );
    }

    positionController.add(
      TtsPlaybackPositionEvent(
        playbackId: currentSource.playbackId,
        requestKey: currentSource.requestKey,
        position: currentSource.playbackOffset + position,
      ),
    );
  }
}
