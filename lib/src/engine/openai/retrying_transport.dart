import 'models.dart';
import 'transport.dart';

final class OpenAiRetryingTransport implements OpenAiTtsTransport {
  OpenAiRetryingTransport({
    required OpenAiTtsTransport inner,
    this.maxRetries = 2,
    this.initialBackoff = const Duration(milliseconds: 250),
    Future<void> Function(Duration)? delay,
  })  : _inner = inner,
        _delay = delay ?? Future<void>.delayed;

  final OpenAiTtsTransport _inner;
  final int maxRetries;
  final Duration initialBackoff;
  final Future<void> Function(Duration) _delay;

  @override
  Future<OpenAiTtsResponse> synthesize(OpenAiTtsRequest request) async {
    var attempt = 0;
    while (true) {
      try {
        return await _inner.synthesize(request);
      } on OpenAiTransportException catch (error) {
        final canRetry = error.isRetryable && attempt < maxRetries;
        if (!canRetry) {
          rethrow;
        }
        final backoff = _scale(initialBackoff, attempt + 1);
        await _delay(backoff);
        attempt++;
      }
    }
  }

  Duration _scale(Duration base, int multiplier) {
    return Duration(milliseconds: base.inMilliseconds * multiplier);
  }
}
