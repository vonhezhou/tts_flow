import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:tts_flow_dart/tts_flow_dart.dart';
import 'package:tts_flow_flutter/tts_flow_flutter.dart';

/// Builds a playback-first output with an asynchronous raw-audio sidecar.
///
/// The primary writes directly to the player. The auxiliary owns a serial file
/// queue and drops remaining work after its first asynchronous failure, so it
/// can never add file-I/O backpressure to playback.
PrioritizedOutput createPlaybackWithAsyncFileAuxiliary(File target) {
  return PrioritizedOutput(
    primary: SpeakerOutput(backend: JustAudioBackend()),
    auxiliaries: [AsyncFileAuxiliary(target)],
  );
}

/// Runs one request with player-first delivery and an independent file sidecar.
///
/// [onAuxiliaryError] is intentionally diagnostic: the primary output and the
/// returned synthesis result keep their normal semantics if the sidecar fails.
Future<TtsSynthesisResult> speakWithAsyncFileAuxiliary({
  required TtsEngine engine,
  required File target,
  required String text,
  void Function(Object error, StackTrace stackTrace)? onAuxiliaryError,
}) async {
  final auxiliary = AsyncFileAuxiliary(target);
  final errors = auxiliary.errors.listen(
    (_) {},
    onError: (Object error, StackTrace stackTrace) {
      onAuxiliaryError?.call(error, stackTrace);
    },
  );
  final flow = TtsFlow(
    engine: engine,
    defaultOutput: PrioritizedOutput(
      primary: SpeakerOutput(backend: JustAudioBackend()),
      auxiliaries: [auxiliary],
    ),
  );

  try {
    await flow.init();
    return await flow.speak(text).synthesisResult;
  } finally {
    await flow.dispose();
    await errors.cancel();
  }
}

/// A reference [TtsAuxiliaryOutput] for an application-owned async sink.
///
/// It serializes work in [_pending], copies bytes before queueing them, emits
/// asynchronous errors to [errors], and uses a drop-after-first-error policy.
/// Replace the file operations with an isolate, WebSocket, or another external
/// processor when that is the application's real destination.
final class AsyncFileAuxiliary implements TtsAuxiliaryOutput {
  AsyncFileAuxiliary(this.target, {this.outputId = 'async-file'});

  final File target;

  @override
  final String outputId;

  final _errors = StreamController<Object>.broadcast();
  Future<void> _pending = Future<void>.value();
  IOSink? _sink;
  var _isDropping = false;
  var _isDisposed = false;

  /// Asynchronous sidecar failures. They are intentionally independent from
  /// the primary output and from the request's synthesis result.
  Stream<Object> get errors => _errors.stream;

  @override
  void init() {}

  @override
  void startWrite(TtsOutputWriteContext writeContext) {
    _enqueue(() {
      _sink = target.openWrite();
    });
  }

  @override
  void writeChunk(TtsChunk chunk) {
    if (chunk is! TtsAudioChunk) {
      return;
    }
    // The engine/output can reuse its input buffer after this synchronous
    // callback returns, so the asynchronous queue owns a copy.
    final bytes = Uint8List.fromList(chunk.bytes);
    _enqueue(() {
      _sink?.add(bytes);
    });
  }

  @override
  void finishWrite() {
    _enqueue(_closeSink);
  }

  @override
  void cancelWrite(SynthesisControl control) {
    _enqueue(_closeSink);
  }

  @override
  void dispose() {
    if (_isDisposed) {
      return;
    }
    _isDisposed = true;
    _append(_closeSink);
    unawaited(_pending.whenComplete(_errors.close));
  }

  void _enqueue(FutureOr<void> Function() operation) {
    if (_isDisposed || _isDropping) {
      return;
    }
    _append(operation);
  }

  void _append(FutureOr<void> Function() operation) {
    _pending = _pending.then((_) async {
      try {
        await operation();
      } catch (error, stackTrace) {
        _isDropping = true;
        if (!_errors.isClosed) {
          _errors.addError(error, stackTrace);
        }
      }
    });
  }

  Future<void> _closeSink() async {
    final sink = _sink;
    _sink = null;
    if (sink != null) {
      await sink.flush();
      await sink.close();
    }
  }
}
