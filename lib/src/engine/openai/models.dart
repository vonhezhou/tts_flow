import 'dart:convert';
import 'dart:typed_data';

final class OpenAiApiRequest {
  const OpenAiApiRequest({
    this.method = 'POST',
    this.endpoint,
    this.headers = const {},
    required this.bodyBytes,
  });

  factory OpenAiApiRequest.json({
    String method = 'POST',
    String? endpoint,
    Map<String, String> headers = const {},
    required String body,
  }) {
    return OpenAiApiRequest(
      method: method,
      endpoint: endpoint,
      headers: headers,
      bodyBytes: Uint8List.fromList(utf8.encode(body)),
    );
  }

  final String method;
  final String? endpoint;
  final Map<String, String> headers;
  final Uint8List bodyBytes;
}

final class OpenAiTransportException implements Exception {
  const OpenAiTransportException({
    required this.statusCode,
    required this.message,
    this.cause,
  });

  final int statusCode;
  final String message;
  final Object? cause;

  bool get isRetryable =>
      statusCode == 408 ||
      statusCode == 429 ||
      statusCode >= 500 ||
      statusCode == 0;
}

final class OpenAiClientConfig {
  const OpenAiClientConfig({
    this.apiKey = '',
    this.endpoint = 'https://api.openai.com/v1/audio/speech',
    this.model = 'gpt-4o-mini-tts',
    this.requestTimeout = const Duration(seconds: 30),
    this.maxRetries = 2,
    this.initialBackoff = const Duration(milliseconds: 250),
  });

  final String apiKey;
  final String endpoint;
  final String model;
  final Duration requestTimeout;
  final int maxRetries;
  final Duration initialBackoff;
}
