/// The duration on a playback session timeline.
class JustAudioDurationEvent {
  /// constructor
  JustAudioDurationEvent({
    required this.playbackId,
    required this.requestId,
    required this.duration,
  });

  /// The playback identifier for the session this segment belongs to.
  final String playbackId;

  /// The request identifier for the TTS request this segment belongs to.
  final String requestId;

  /// The known playback duration on the session timeline.
  ///
  /// This value is cumulative across segments in the same playback session.
  final Duration duration;

  @override
  String toString() =>
      'PlaybackDuration(playbackId: $playbackId, duration: $duration)';
}

/// The position of specific playback on session timeline.
class JustAudioPosEvent {
  /// constructor
  JustAudioPosEvent({
    required this.playbackId,
    required this.requestId,
    required this.position,
  });

  /// The playback identifier for the session this segment belongs to.
  final String playbackId;

  /// The request identifier for the TTS request this segment belongs to.
  final String requestId;

  /// The playback position on the session timeline.
  final Duration position;

  @override
  String toString() => 'PlaybackPos(playbackId: $playbackId, pos: $position)';
}
