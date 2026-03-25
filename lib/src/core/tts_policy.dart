enum TtsQueueFailurePolicy {
  /// fail active request and
  /// cancel all pending requests on first failure
  failFast,

  /// skip failed request and continue with next pending request
  continueOnError,
}

enum TtsPauseBufferPolicy {
  /// Buffer chunks received from the engine during a pause and flush them
  /// to the output when the request is resumed.
  buffered,

  /// Pass chunks directly to the output even while paused.
  passthrough,
}

/// Reason associated with cancellation of an active synthesis request.
enum CancelReason {
  /// Cancellation requested explicitly via [TtsFlow.stopCurrent].
  stopCurrent,

  /// Cancellation initiated because the service is being disposed.
  serviceDispose,
}
