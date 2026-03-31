/// The duration of a playback.
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

  /// The playback duration of this segment.
  final Duration duration;

  @override
  String toString() =>
      'PlaybackDuration(playbackId: $playbackId, duration: $duration)';
}

/// The position of spcific playback.
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

  /// The playback position of this segment.
  final Duration position;

  @override
  String toString() => 'PlaybackPos(playbackId: $playbackId, pos: $position)';
}
