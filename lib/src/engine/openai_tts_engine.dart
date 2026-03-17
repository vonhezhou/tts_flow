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
  });

  final int statusCode;
  final String message;
}

abstract interface class OpenAiTtsTransport {
  Future<OpenAiTtsResponse> synthesize(OpenAiTtsRequest request);
}

final class OpenAiTtsEngine implements TtsEngine {
  OpenAiTtsEngine({
    required this.transport,
    this.engineId = 'openai',
    this.defaultVoiceId = 'alloy',
    this.nonStreamingChunkSizeBytes = 4096,
  });

  final OpenAiTtsTransport transport;
  @override
  final String engineId;
  final String defaultVoiceId;
  final int nonStreamingChunkSizeBytes;

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
