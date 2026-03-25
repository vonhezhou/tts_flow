import 'package:tts_flow_dart/src/core/tts_policy.dart';

final class SynthesisControl {
  CancelReason? _cancelReason;
  String? _cancelMessage;

  bool get isCanceled => _cancelReason != null;
  CancelReason? get cancelReason => _cancelReason;
  String? get cancelMessage => _cancelMessage;

  /// Cancels synthesis.
  ///
  /// Cancellation metadata is first-write-wins to keep cancellation cause
  /// stable when multiple callers race to cancel the same request.
  void cancel(CancelReason reason, {String? message}) {
    _cancelReason ??= reason;
    _cancelMessage ??= message;
  }
}
