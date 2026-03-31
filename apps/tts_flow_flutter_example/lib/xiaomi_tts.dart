import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:tts_flow_dart/tts_flow_dart.dart';

class XiaomiTts extends OpenAiTtsEngine {
  static const String _openAiDefaultEndpoint =
      'https://api.openai.com/v1/audio/speech';
  static const String _openAiDefaultModel = 'gpt-4o-mini-tts';
  static const String xiaomiEndpoint =
      'https://api.xiaomimimo.com/v1/chat/completions';
  static const String xiaomiModel = 'mimo-v2-tts';
  static const String xiaomiDefaultVoice = 'default_en';
  static const String _apiKeyEnvVar = 'XIAOMI_MIMO_API_KEY';

  static const List<TtsVoice> xiaomiVoices = [
    TtsVoice(voiceId: 'mimo_default', displayName: 'Mimo Default'),
    TtsVoice(voiceId: 'default_zh', displayName: 'Chinese'),
    TtsVoice(voiceId: 'default_en', displayName: 'English', isDefault: true),
  ];

  XiaomiTts.fromClientConfig({
    required OpenAiClientConfig config,
    super.engineId = 'xiaomi-mimo',
    super.defaultVoiceId = xiaomiDefaultVoice,
    super.nonStreamingChunkSizeBytes,
    Future<void> Function(Duration)? delay,
  }) : _effectiveApiKey = config.apiKey.isNotEmpty
           ? config.apiKey
           : const String.fromEnvironment(_apiKeyEnvVar),
       _configuredEndpoint = _resolveEndpointFromConfig(config.endpoint),
       _configuredModel = _resolveModelFromConfig(config.model),
       super(
         apiClient: _createApiClient(config, delay),
         model: _resolveModelFromConfig(config.model),
         apiKey: config.apiKey.isNotEmpty
             ? config.apiKey
             : const String.fromEnvironment(_apiKeyEnvVar),
         voiceCatalogOverrides: {
           _resolveModelFromConfig(config.model): xiaomiVoices,
         },
       );

  final String _effectiveApiKey;
  final String _configuredEndpoint;
  final String _configuredModel;
  final Map<String, PcmDescriptor> _resolvedPcmByRequest =
      <String, PcmDescriptor>{};

  static String _resolveEndpointFromConfig(String endpoint) {
    final trimmed = endpoint.trim();
    if (trimmed.isEmpty || trimmed == _openAiDefaultEndpoint) {
      return xiaomiEndpoint;
    }
    return trimmed;
  }

  static String _resolveModelFromConfig(String model) {
    final trimmed = model.trim();
    if (trimmed.isEmpty || trimmed == _openAiDefaultModel) {
      return xiaomiModel;
    }
    return trimmed;
  }

  static OpenAiApiClient _createApiClient(
    OpenAiClientConfig config,
    Future<void> Function(Duration)? delay,
  ) {
    final baseClient = OpenAiHttpApiClient(config: config);
    if (config.maxRetries <= 0) {
      return baseClient;
    }
    return OpenAiRetryingApiClient(
      inner: baseClient,
      maxRetries: config.maxRetries,
      initialBackoff: config.initialBackoff,
      delay: delay,
    );
  }

  @override
  Set<AudioCapability> get outAudioCapabilities => {
    const Mp3Capability(),
    PcmCapability.wav(),
  };

  @override
  String? resolveEndpoint(TtsRequest request, TtsAudioSpec resolvedFormat) {
    return _configuredEndpoint;
  }

  @override
  Map<String, String> buildRequestHeaders(
    TtsRequest request,
    TtsAudioSpec resolvedFormat,
  ) {
    final headers = <String, String>{
      'Content-Type': 'application/json',
      'Accept': 'text/event-stream',
    };

    if (_effectiveApiKey.isNotEmpty) {
      headers['Authorization'] = 'Bearer $_effectiveApiKey';
    }

    return headers;
  }

  @override
  String buildRequestBody(TtsRequest request, TtsAudioSpec resolvedFormat) {
    final voiceId = request.voice?.voiceId ?? xiaomiDefaultVoice;
    return jsonEncode({
      'model': _configuredModel,
      'messages': [
        {'role': 'assistant', 'content': request.text},
      ],
      'audio': {'format': mapFormat(resolvedFormat.format), 'voice': voiceId},
      'stream': true,
    });
  }

  @override
  String mapFormat(TtsAudioFormat format) {
    switch (format) {
      case TtsAudioFormat.mp3:
        return 'mp3';
      case TtsAudioFormat.pcm:
        return 'wav';
      case TtsAudioFormat.opus:
      case TtsAudioFormat.aac:
        throw UnsupportedError(
          'Xiaomi Mimo only supports mp3 and wav (pcm) formats.',
        );
    }
  }

  @override
  Stream<TtsChunk> synthesize(
    TtsRequest request,
    SynthesisControl control,
    TtsAudioSpec resolvedFormat,
  ) async* {
    try {
      await for (final chunk in super.synthesize(
        request,
        control,
        resolvedFormat,
      )) {
        if (chunk is! TtsAudioChunk) {
          yield chunk;
          continue;
        }

        if (resolvedFormat.format != TtsAudioFormat.pcm) {
          yield chunk;
          continue;
        }

        final descriptor = _resolvedPcmByRequest[request.requestId];
        if (descriptor == null) {
          yield chunk;
          continue;
        }

        yield TtsAudioChunk(
          requestId: chunk.requestId,
          sequenceNumber: chunk.sequenceNumber,
          bytes: chunk.bytes,
          audioSpec: TtsAudioSpec.pcm(descriptor),
          isLastChunk: chunk.isLastChunk,
          timestamp: chunk.timestamp,
        );
      }
    } finally {
      _resolvedPcmByRequest.remove(request.requestId);
    }
  }

  @override
  Stream<List<int>> parseSuccessResponse(
    http.StreamedResponse response,
    TtsRequest request,
    TtsAudioFormat resolvedFormat,
  ) async* {
    final lineBuffer = StringBuffer();
    final shouldNormalizeWav = resolvedFormat == TtsAudioFormat.pcm;
    var isDone = false;

    await for (final bytes in response.stream) {
      if (isDone) {
        break;
      }

      lineBuffer.write(utf8.decode(bytes, allowMalformed: true));
      final buffered = lineBuffer.toString();
      final lines = buffered.split('\n');

      lineBuffer
        ..clear()
        ..write(lines.removeLast());

      for (final line in lines) {
        final audioChunk = _parseAudioChunkFromLine(line);
        if (audioChunk == null) {
          continue;
        }
        if (audioChunk.isDone) {
          isDone = true;
          break;
        }
        if (audioChunk.audioBytes.isNotEmpty) {
          if (!shouldNormalizeWav) {
            yield audioChunk.audioBytes;
            continue;
          }

          final normalized = _stripWavHeaderIfPresent(
            Uint8List.fromList(audioChunk.audioBytes),
            onHeader: (descriptor) {
              _resolvedPcmByRequest[request.requestId] = descriptor;
            },
          );
          if (normalized != null && normalized.isNotEmpty) {
            yield normalized;
          }
        }
      }
    }

    if (isDone) {
      return;
    }

    final finalChunk = _parseAudioChunkFromLine(lineBuffer.toString());
    if (finalChunk != null &&
        !finalChunk.isDone &&
        finalChunk.audioBytes.isNotEmpty) {
      if (!shouldNormalizeWav) {
        yield finalChunk.audioBytes;
        return;
      }

      final normalized = _stripWavHeaderIfPresent(
        Uint8List.fromList(finalChunk.audioBytes),
        onHeader: (descriptor) {
          _resolvedPcmByRequest[request.requestId] = descriptor;
        },
      );
      if (normalized != null && normalized.isNotEmpty) {
        yield normalized;
      }
    }
  }

  List<int>? _stripWavHeaderIfPresent(
    Uint8List bytes, {
    void Function(PcmDescriptor descriptor)? onHeader,
  }) {
    if (bytes.length < 44) {
      return null;
    }

    try {
      final header = WavHeader.parse(bytes.sublist(0, 44));
      onHeader?.call(header.toPcmDescriptor());
      return bytes.sublist(44);
    } catch (_) {
      // If payload is not a WAV container, treat it as raw PCM bytes.
      return bytes;
    }
  }

  @override
  String parseErrorResponse(int statusCode, Uint8List bodyBytes) {
    if (bodyBytes.isEmpty) {
      return 'Xiaomi Mimo request failed with status $statusCode.';
    }

    try {
      final dynamic decoded = jsonDecode(utf8.decode(bodyBytes));
      if (decoded is Map<String, dynamic>) {
        final error = decoded['error'];
        if (error is Map<String, dynamic>) {
          final message = error['message'];
          if (message is String && message.trim().isNotEmpty) {
            return message;
          }
        }

        final message = decoded['message'];
        if (message is String && message.trim().isNotEmpty) {
          return message;
        }
      }
    } catch (_) {
      // Fall through to raw body when response is not JSON.
    }

    return utf8.decode(bodyBytes, allowMalformed: true);
  }

  _ParsedAudioChunk? _parseAudioChunkFromLine(String line) {
    var payload = line.trim();
    if (payload.isEmpty) {
      return null;
    }

    if (payload.startsWith('data:')) {
      payload = payload.substring(5).trim();
    }

    if (payload.isEmpty) {
      return null;
    }

    if (payload == '[DONE]') {
      return const _ParsedAudioChunk.done();
    }

    try {
      final dynamic decoded = jsonDecode(payload);
      if (decoded is! Map<String, dynamic>) {
        return null;
      }

      final choices = decoded['choices'];
      if (choices is! List || choices.isEmpty) {
        return null;
      }

      final firstChoice = choices.first;
      if (firstChoice is! Map<String, dynamic>) {
        return null;
      }

      final delta = firstChoice['delta'];
      if (delta is! Map<String, dynamic>) {
        return null;
      }

      final audio = delta['audio'];
      if (audio is! Map<String, dynamic>) {
        return null;
      }

      final base64Data = audio['data'];
      if (base64Data is! String || base64Data.isEmpty) {
        return null;
      }

      return _ParsedAudioChunk(audioBytes: base64Decode(base64Data));
    } catch (_) {
      return null;
    }
  }
}

class _ParsedAudioChunk {
  const _ParsedAudioChunk({required this.audioBytes}) : isDone = false;
  const _ParsedAudioChunk.done() : audioBytes = const <int>[], isDone = true;

  final List<int> audioBytes;
  final bool isDone;
}
