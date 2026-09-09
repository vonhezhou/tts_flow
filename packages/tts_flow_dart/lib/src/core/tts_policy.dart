enum TtsQueueFailurePolicy {
  /// fail active request and
  /// cancel all pending requests on first failure
  failFast,

  /// skip failed request and continue with next pending request
  continueOnError,
}

/// Reason associated with cancellation of an active synthesis request.
enum CancelReason {
  /// Cancellation requested explicitly through a request handle or flow-wide
  /// active-synthesis control.
  stopCurrent,

  /// Cancellation initiated because the service is being disposed.
  serviceDispose,
}
