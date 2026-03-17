import 'dart:typed_data';

import '../../core/tts_models.dart';

final class OpenAiTtsRequest {
  const OpenAiTtsRequest({
    required this.text,
    required this.voiceId,
    required this.format,
    this.model = 'gpt-4o-mini-tts',
  });

  final String text;
  final String voiceId;
  final TtsAudioFormat format;
  final String model;
}

final class OpenAiTtsResponse {
  const OpenAiTtsResponse({required this.audioBytes});

  final Uint8List audioBytes;
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
    required this.apiKey,
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
