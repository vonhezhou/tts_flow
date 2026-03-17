import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../core/tts_contracts.dart';
import '../core/tts_errors.dart';
import '../core/tts_models.dart';
import 'non_streaming_bridge.dart';

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

abstract interface class OpenAiTtsTransport {
  Future<OpenAiTtsResponse> synthesize(OpenAiTtsRequest request);
}

final class OpenAiHttpTtsTransport implements OpenAiTtsTransport {
  OpenAiHttpTtsTransport({
    required OpenAiClientConfig config,
    HttpClient? httpClient,
  })  : _config = config,
        _httpClient = httpClient ?? HttpClient();

  final OpenAiClientConfig _config;
  final HttpClient _httpClient;

  @override
  Future<OpenAiTtsResponse> synthesize(OpenAiTtsRequest request) async {
    if (_config.apiKey.isEmpty) {
      throw const OpenAiTransportException(
        statusCode: 401,
        message: 'OpenAI API key is missing.',
      );
    }

    final uri = Uri.parse(_config.endpoint);
    final httpRequest = await _httpClient.postUrl(uri);
    httpRequest.headers
        .set(HttpHeaders.authorizationHeader, 'Bearer ${_config.apiKey}');
    httpRequest.headers.set(HttpHeaders.contentTypeHeader, 'application/json');

    final body = jsonEncode({
      'model': request.model,
      'input': request.text,
      'voice': request.voiceId,
      'response_format': _mapFormat(request.format),
    });

    httpRequest.write(body);

    HttpClientResponse response;
    try {
      response = await httpRequest.close().timeout(
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

    final bytes = await response.fold<BytesBuilder>(
      BytesBuilder(copy: false),
      (builder, data) {
        builder.add(data);
        return builder;
      },
    );
    final payload = bytes.takeBytes();

    if (response.statusCode != HttpStatus.ok) {
      final message = payload.isEmpty
          ? 'OpenAI request failed with status ${response.statusCode}.'
          : utf8.decode(payload, allowMalformed: true);
      throw OpenAiTransportException(
        statusCode: response.statusCode,
        message: message,
      );
    }

    return OpenAiTtsResponse(audioBytes: payload);
  }

  String _mapFormat(TtsAudioFormat format) {
    switch (format) {
      case TtsAudioFormat.pcm16:
        return 'pcm';
      case TtsAudioFormat.mp3:
        return 'mp3';
      case TtsAudioFormat.wav:
        return 'wav';
      case TtsAudioFormat.oggOpus:
        return 'opus';
      case TtsAudioFormat.aac:
        return 'aac';
    }
  }
}

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

final class OpenAiTtsEngine implements TtsEngine {
  OpenAiTtsEngine({
    required this.transport,
    this.engineId = 'openai',
    this.defaultVoiceId = 'alloy',
    this.nonStreamingChunkSizeBytes = 4096,
    this.model = 'gpt-4o-mini-tts',
  });

  final OpenAiTtsTransport transport;
  @override
  final String engineId;
  final String defaultVoiceId;
  final int nonStreamingChunkSizeBytes;
  final String model;

  @override
  bool get supportsStreaming => false;

  @override
  bool get supportsPause => false;

  @override
  Set<TtsAudioFormat> get supportedFormats => {
        TtsAudioFormat.mp3,
        TtsAudioFormat.wav,
        TtsAudioFormat.aac,
      };

  @override
  Stream<TtsChunk> synthesize(
    TtsRequest request,
    TtsControlToken controlToken,
    TtsAudioFormat resolvedFormat,
  ) async* {
    try {
      final response = await transport.synthesize(
        OpenAiTtsRequest(
          text: request.text,
          voiceId: request.voice?.voiceId ?? defaultVoiceId,
          format: resolvedFormat,
          model: model,
        ),
      );

      if (controlToken.isStopped) {
        return;
      }

      yield* NonStreamingBridge.toChunkStream(
        requestId: request.requestId,
        format: resolvedFormat,
        audioBytes: response.audioBytes,
        chunkSizeBytes: nonStreamingChunkSizeBytes,
      );
    } on OpenAiTransportException catch (error) {
      throw TtsError(
        code: _mapStatusCode(error.statusCode),
        message: error.message,
        requestId: request.requestId,
        cause: error,
      );
    } catch (error) {
      throw TtsError(
        code: TtsErrorCode.networkError,
        message: 'OpenAI TTS request failed.',
        requestId: request.requestId,
        cause: error,
      );
    }
  }

  TtsErrorCode _mapStatusCode(int statusCode) {
    if (statusCode == 401 || statusCode == 403) {
      return TtsErrorCode.authFailed;
    }
    if (statusCode == 408 || statusCode == 504) {
      return TtsErrorCode.timeout;
    }
    if (statusCode >= 500) {
      return TtsErrorCode.networkError;
    }
    return TtsErrorCode.internalError;
  }

  @override
  Future<void> dispose() async {}
}
