import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../../core/tts_models.dart';
import 'models.dart';
import 'transport.dart';

final class OpenAiHttpTtsTransport implements OpenAiTtsTransport {
  OpenAiHttpTtsTransport({
    required OpenAiClientConfig config,
    HttpClient? httpClient,
  })  : _config = config,
        _httpClient = httpClient ?? HttpClient();

  final OpenAiClientConfig _config;
  final HttpClient _httpClient;

  @override
  Stream<List<int>> synthesize(OpenAiTtsRequest request) async* {
    final response = await _sendRequest(request);

    if (response.statusCode != HttpStatus.ok) {
      final payload = await response.fold<BytesBuilder>(
        BytesBuilder(copy: false),
        (builder, data) {
          builder.add(data);
          return builder;
        },
      );
      final errorBytes = payload.takeBytes();
      final message = errorBytes.isEmpty
          ? 'OpenAI request failed with status ${response.statusCode}.'
          : utf8.decode(errorBytes, allowMalformed: true);
      throw OpenAiTransportException(
        statusCode: response.statusCode,
        message: message,
      );
    }

    try {
      await for (final data in response) {
        yield data;
      }
    } on OpenAiTransportException {
      rethrow;
    } catch (error) {
      throw OpenAiTransportException(
        statusCode: 0,
        message: 'OpenAI response stream failed.',
        cause: error,
      );
    }
  }

  Future<HttpClientResponse> _sendRequest(OpenAiTtsRequest request) async {
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

    final body = _buildBody(request);

    httpRequest.write(body);

    try {
      return await httpRequest.close().timeout(
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

  String _buildBody(OpenAiTtsRequest request) {
    return jsonEncode({
      'model': request.model,
      'input': request.text,
      'voice': request.voiceId,
      'response_format': _mapFormat(request.format),
    });
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
