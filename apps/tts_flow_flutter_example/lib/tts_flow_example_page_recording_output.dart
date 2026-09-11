part of 'tts_flow_example_page.dart';

/// Example-side recording observer for [PrioritizedOutput].
///
/// It owns serial file delivery itself, which is deliberately not a
/// responsibility of tts_flow's primary/auxiliary output wrapper.
final class _RecordingAuxiliaryOutput implements TtsAuxiliaryOutput {
  _RecordingAuxiliaryOutput({required this.output, required this.log});

  final TtsOutput output;
  final Logger log;
  Future<void> _pending = Future<void>.value();
  var _hasSession = false;

  @override
  String get outputId => 'example-wav-recorder';

  @override
  void init() {
    _enqueue('init', output.init);
  }

  @override
  void startWrite(TtsOutputWriteContext writeContext) {
    _hasSession = true;
    _enqueue('startWrite', () => output.startWrite(writeContext));
  }

  @override
  void writeChunk(TtsChunk chunk) {
    if (_hasSession) {
      _enqueue('writeChunk', () => output.writeChunk(chunk));
    }
  }

  @override
  void finishWrite() {
    if (!_hasSession) {
      return;
    }
    _hasSession = false;
    _enqueue('finishWrite', () async {
      await output.finishWrite();
    });
  }

  @override
  void cancelWrite(SynthesisControl control) {
    if (!_hasSession) {
      return;
    }
    _hasSession = false;
    _enqueue('cancelWrite', () => output.cancelWrite(control));
  }

  @override
  void dispose() {
    _hasSession = false;
    _enqueue('dispose', output.dispose);
  }

  void _enqueue(String operation, Future<void> Function() action) {
    _pending = _pending
        .catchError((Object error, StackTrace stackTrace) {
          log.warning('Auxiliary audio recorder failed.', error, stackTrace);
        })
        .then<void>((_) => action())
        .catchError((Object error, StackTrace stackTrace) {
          log.warning(
            'Auxiliary audio recorder failed during $operation.',
            error,
            stackTrace,
          );
        });
  }
}
