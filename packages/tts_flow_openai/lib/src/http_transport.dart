import 'package:http/http.dart' as http;

// HTTP transport for the OpenAI adapter.

import 'models.dart';
import 'transport.dart';

class OpenAiHttpApiClient implements OpenAiDisposableApiClient {
  OpenAiHttpApiClient({
    required OpenAiClientConfig config,
    http.Client? httpClient,
  }) : _config = config,
       _httpClient = httpClient ?? http.Client(),
       _ownsHttpClient = httpClient == null;

  final OpenAiClientConfig _config;
  final http.Client _httpClient;
  final bool _ownsHttpClient;

  @override
  Future<http.StreamedResponse> send(OpenAiApiRequest request) async {
    final endpoint = request.endpoint ?? _config.endpoint;
    final uri = Uri.parse(endpoint);
    final httpRequest = http.Request(request.method, uri)
      ..headers.addAll(request.headers)
      ..bodyBytes = request.bodyBytes;

    try {
      return await _httpClient
          .send(httpRequest)
          .timeout(
            _config.requestTimeout,
            onTimeout: () => throw const OpenAiTransportException(
              statusCode: 408,
              message: 'OpenAI request timed out.',
            ),
          );
    } on OpenAiTransportException {
      rethrow;
    } catch (error) {
      throw OpenAiTransportException(
        statusCode: 0,
        message: 'OpenAI network request failed.',
        cause: error,
      );
    }
  }

  @override
  Future<void> dispose() async {
    if (_ownsHttpClient) {
      _httpClient.close();
    }
  }
}
