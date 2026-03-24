import 'package:http/http.dart' as http;

import 'models.dart';
import 'transport.dart';

final class OpenAiRetryingApiClient implements OpenAiApiClient {
  OpenAiRetryingApiClient({
    required OpenAiApiClient inner,
    this.maxRetries = 2,
    this.initialBackoff = const Duration(milliseconds: 250),
    Future<void> Function(Duration)? delay,
  })  : _inner = inner,
        _delay = delay ?? Future<void>.delayed;

  final OpenAiApiClient _inner;
  final int maxRetries;
  final Duration initialBackoff;
  final Future<void> Function(Duration) _delay;

  @override
  Future<http.StreamedResponse> send(OpenAiApiRequest request) async {
    return _runWithRetry(() => _inner.send(request));
  }

  Future<T> _runWithRetry<T>(Future<T> Function() op) async {
    var attempt = 0;
    while (true) {
      try {
        return await op();
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
