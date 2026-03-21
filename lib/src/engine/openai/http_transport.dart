import 'package:http/http.dart' as http;

import 'models.dart';
import 'transport.dart';

class OpenAiHttpApiClient implements OpenAiApiClient {
  OpenAiHttpApiClient({
    required OpenAiClientConfig config,
    http.Client? httpClient,
  })  : _config = config,
        _httpClient = httpClient ?? http.Client();

  final OpenAiClientConfig _config;
  final http.Client _httpClient;

  @override
  Future<http.StreamedResponse> send(OpenAiApiRequest request) async {
    final endpoint = request.endpoint ?? _config.endpoint;
    final uri = Uri.parse(endpoint);
    final httpRequest = http.Request(request.method, uri)
      ..headers.addAll(request.headers)
      ..bodyBytes = request.bodyBytes;

    try {
      return await _httpClient.send(httpRequest).timeout(
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
}
