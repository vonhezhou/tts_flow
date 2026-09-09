/// Decides whether a flow may begin its next queued synthesis request.
///
/// The policy governs synthesis look-ahead only. It does not create a
/// playback queue, mix audio, or change an output's write lifecycle.
abstract interface class TtsSynthesisAdmissionPolicy {
  /// Returns whether the next queued request may begin synthesis.
  bool allowsNextSynthesis(TtsSynthesisAdmissionSnapshot snapshot);
}

/// State supplied to [TtsSynthesisAdmissionPolicy] when the flow considers
/// starting another request.
final class TtsSynthesisAdmissionSnapshot {
  const TtsSynthesisAdmissionSnapshot({
    required this.pendingRequestCount,
    required this.outstandingPlaybackRequestCount,
  });

  /// Number of text requests still waiting to begin synthesis.
  final int pendingRequestCount;

  /// Number of requests whose output still exposes controllable physical
  /// playback.
  ///
  /// This includes audio currently playing and audio already accepted by a
  /// queued playback backend but not yet physically terminal. Outputs without
  /// [PlaybackControllableOutput]-style lifecycle tracking contribute zero.
  final int outstandingPlaybackRequestCount;
}

/// Default policy: start every queued request as soon as the preceding output
/// write has ended.
final class TtsEagerSynthesisAdmissionPolicy
    implements TtsSynthesisAdmissionPolicy {
  const TtsEagerSynthesisAdmissionPolicy();

  @override
  bool allowsNextSynthesis(TtsSynthesisAdmissionSnapshot snapshot) => true;
}

/// Limits ahead-of-playback synthesis for an output that retains physical
/// playback state after its input has finalized.
///
/// For example, with [maxOutstandingPlaybackRequests] set to two, A may be
/// physically playing while B is synthesized and queued behind it. C waits
/// until either A or B reaches a physical playback terminal state. This keeps
/// at most two requests' audio in the playback backlog while preserving one
/// request of pre-synthesis.
///
/// The policy only observes the flow's playback associations. It does not make
/// a non-queueing player serial, so use it with an output/backend that can
/// accept ordered playback sessions such as the bundled JustAudio backend.
final class TtsBoundedPlaybackBacklogPolicy
    implements TtsSynthesisAdmissionPolicy {
  const TtsBoundedPlaybackBacklogPolicy({
    required this.maxOutstandingPlaybackRequests,
  }) : assert(maxOutstandingPlaybackRequests > 0);

  /// Maximum count of physically non-terminal playback requests, including
  /// the one currently audible.
  final int maxOutstandingPlaybackRequests;

  @override
  bool allowsNextSynthesis(TtsSynthesisAdmissionSnapshot snapshot) =>
      snapshot.outstandingPlaybackRequestCount < maxOutstandingPlaybackRequests;
}
