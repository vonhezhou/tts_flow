import 'dart:io';

import '../../core/tts_contracts.dart';
import '../../core/tts_errors.dart';
import '../../core/tts_models.dart';
import '../non_streaming_bridge.dart';
import 'http_transport.dart';
import 'models.dart';
import 'retrying_transport.dart';
import 'transport.dart';

final class OpenAiTtsEngine implements TtsEngine {
  OpenAiTtsEngine({
    required this.transport,
    this.engineId = 'openai',
    this.defaultVoiceId = 'alloy',
    this.nonStreamingChunkSizeBytes = 4096,
    this.model = 'gpt-4o-mini-tts',
  });

  factory OpenAiTtsEngine.fromClientConfig({
    required OpenAiClientConfig config,
    String engineId = 'openai',
    String defaultVoiceId = 'alloy',
    int nonStreamingChunkSizeBytes = 4096,
    HttpClient? httpClient,
    Future<void> Function(Duration)? delay,
  }) {
    final baseTransport = OpenAiHttpTtsTransport(
      config: config,
      httpClient: httpClient,
    );

    final transport = config.maxRetries > 0
        ? OpenAiRetryingTransport(
            inner: baseTransport,
            maxRetries: config.maxRetries,
            initialBackoff: config.initialBackoff,
            delay: delay,
          )
        : baseTransport;

    return OpenAiTtsEngine(
      transport: transport,
      engineId: engineId,
      defaultVoiceId: defaultVoiceId,
      nonStreamingChunkSizeBytes: nonStreamingChunkSizeBytes,
      model: config.model,
    );
  }

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
