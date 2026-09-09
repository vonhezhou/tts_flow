import 'package:tts_flow_dart/src/core/synthesis_control.dart';
import 'package:tts_flow_dart/src/core/tts_chunk.dart';
import 'package:tts_flow_dart/src/core/tts_output_write_context.dart';

/// A non-blocking observer of a [PrioritizedOutput] write.
///
/// Every method is a synchronous notification. An implementation may begin
/// asynchronous work, but it must manage its own ordering, buffering, error
/// handling, and finalization. In particular, it must return promptly: a
/// synchronous, CPU-intensive implementation still blocks the Dart isolate
/// even though the primary output is not awaiting it.
///
/// Auxiliary outputs do not take part in format negotiation. They receive the
/// format selected for the primary [TtsOutput] and must decide for themselves
/// whether and how to consume it.
abstract interface class TtsAuxiliaryOutput {
  /// Stable identifier used in [TtsAuxiliaryOutputError] diagnostics.
  String get outputId;

  /// Performs output-wide setup without blocking the primary output.
  void init();

  /// Notifies this output that a request-scoped write has started.
  void startWrite(TtsOutputWriteContext writeContext);

  /// Delivers one chunk after the primary output has accepted it.
  void writeChunk(TtsChunk chunk);

  /// Notifies this output that the primary output finalized successfully.
  void finishWrite();

  /// Notifies this output that the primary write was canceled.
  void cancelWrite(SynthesisControl control);

  /// Releases output-wide resources.
  void dispose();
}

/// The point in an auxiliary output lifecycle at which a synchronous error
/// occurred.
enum TtsAuxiliaryOutputStage {
  init,
  startWrite,
  writeChunk,
  finishWrite,
  cancelWrite,
  dispose,
}

/// A synchronous auxiliary-output error observed by [PrioritizedOutput].
///
/// The error is diagnostic only: it never fails or delays the primary output.
/// Asynchronous errors belong to the auxiliary implementation itself, because
/// [TtsAuxiliaryOutput] deliberately has no asynchronous delivery contract.
final class TtsAuxiliaryOutputError {
  const TtsAuxiliaryOutputError({
    required this.outputId,
    required this.stage,
    required this.error,
    required this.stackTrace,
    this.requestKey,
  });

  final String outputId;
  final TtsAuxiliaryOutputStage stage;
  final Object error;
  final StackTrace stackTrace;
  final String? requestKey;
}
