/// A position reported on the physical playback timeline for one request.
///
/// [position] is measured from the beginning of the audio rendered for
/// [requestId], rather than from the current platform playlist item.
final class TtsPlaybackPositionEvent {
  const TtsPlaybackPositionEvent({
    required this.requestId,
    required this.playbackId,
    required this.position,
  });

  final String requestId;
  final String playbackId;
  final Duration position;
}

/// Optional capability implemented by playback backends that can report a
/// continuous, request-scoped physical playback timeline.
///
/// This is intentionally separate from [SpeakerBackend]'s base contract:
/// basic speaker implementations do not need position reporting to play
/// audio correctly.
abstract interface class PlaybackTimelineReporter {
  Stream<TtsPlaybackPositionEvent> get playbackPositionEvents;
}
