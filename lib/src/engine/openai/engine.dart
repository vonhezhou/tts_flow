import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:tts_flow_dart/src/base/audio_capability.dart';
import 'package:tts_flow_dart/src/base/audio_spec.dart';

import '../../core/tts_contracts.dart';
import '../../core/tts_errors.dart';
import '../../core/tts_models.dart';
import 'http_transport.dart';
import 'models.dart';
import 'retrying_transport.dart';
import 'transport.dart';

class OpenAiTtsEngine implements TtsEngine {
  OpenAiTtsEngine({
    required this.apiClient,
    this.engineId = 'openai',
    this.defaultVoiceId = 'alloy',
    this.nonStreamingChunkSizeBytes = 4096,
    this.model = 'gpt-4o-mini-tts',
    this.apiKey = '',
    this.voiceCatalogOverrides,
  });

  factory OpenAiTtsEngine.fromClientConfig({
    required OpenAiClientConfig config,
    String engineId = 'openai',
    String defaultVoiceId = 'alloy',
    int nonStreamingChunkSizeBytes = 4096,
    http.Client? httpClient,
    Future<void> Function(Duration)? delay,
    Map<String, List<TtsVoice>>? voiceCatalogOverrides,
  }) {
    final baseClient = OpenAiHttpApiClient(
      config: config,
      httpClient: httpClient,
    );

    final apiClient = config.maxRetries > 0
        ? OpenAiRetryingApiClient(
            inner: baseClient,
            maxRetries: config.maxRetries,
            initialBackoff: config.initialBackoff,
            delay: delay,
          )
        : baseClient;

    return OpenAiTtsEngine(
      apiClient: apiClient,
      engineId: engineId,
      defaultVoiceId: defaultVoiceId,
      nonStreamingChunkSizeBytes: nonStreamingChunkSizeBytes,
      model: config.model,
      apiKey: config.apiKey,
      voiceCatalogOverrides: voiceCatalogOverrides,
    );
  }

  final OpenAiApiClient apiClient;
  @override
  final String engineId;
  final String defaultVoiceId;
  final int nonStreamingChunkSizeBytes;
  final String model;
  final String apiKey;
  final Map<String, List<TtsVoice>>? voiceCatalogOverrides;

  static const Map<String, List<TtsVoice>> _builtInCatalog = {
    'tts-1': [
      TtsVoice(voiceId: 'alloy'),
      TtsVoice(voiceId: 'echo'),
      TtsVoice(voiceId: 'fable'),
      TtsVoice(voiceId: 'nova'),
      TtsVoice(voiceId: 'onyx'),
      TtsVoice(voiceId: 'shimmer'),
    ],
    'tts-1-hd': [
      TtsVoice(voiceId: 'alloy'),
      TtsVoice(voiceId: 'echo'),
      TtsVoice(voiceId: 'fable'),
      TtsVoice(voiceId: 'nova'),
      TtsVoice(voiceId: 'onyx'),
      TtsVoice(voiceId: 'shimmer'),
    ],
    'gpt-4o-mini-tts': [
      TtsVoice(voiceId: 'alloy'),
      TtsVoice(voiceId: 'ash'),
      TtsVoice(voiceId: 'ballad'),
      TtsVoice(voiceId: 'coral'),
      TtsVoice(voiceId: 'echo'),
      TtsVoice(voiceId: 'fable'),
      TtsVoice(voiceId: 'nova'),
      TtsVoice(voiceId: 'onyx'),
      TtsVoice(voiceId: 'sage'),
      TtsVoice(voiceId: 'shimmer'),
      TtsVoice(voiceId: 'verse'),
    ],
  };

  static const List<String> _fallbackVoiceIds = [
    'alloy',
    'echo',
    'fable',
    'nova',
    'onyx',
    'shimmer',
  ];

  @override
  bool get supportsStreaming => true;

  @override
  Set<AudioCapability> get supportedCapabilities => {
        const SimpleFormatCapability(format: TtsAudioFormat.mp3),
        const SimpleFormatCapability(format: TtsAudioFormat.wav),
        const SimpleFormatCapability(format: TtsAudioFormat.aac),
      };

  @override
  Future<List<TtsVoice>> getAvailableVoices({String? locale}) async {
    final voices = _resolveVoices();
    if (locale == null || locale.trim().isEmpty) {
      return voices;
    }

    final normalizedLocale = _normalizeLocale(locale);
    final scoped = voices.where((voice) {
      return _localeMatches(voice.locale, normalizedLocale);
    }).toList(growable: false);

    // If provider metadata does not include locales, do not hide voices.
    if (scoped.isEmpty && voices.every((voice) => voice.locale == null)) {
      return voices;
    }

    return scoped;
  }

  @override
  Future<TtsVoice> getDefaultVoice() async {
    final voices = _resolveVoices();

    for (final voice in voices) {
      if (voice.isDefault) {
        return voice;
      }
    }
    for (final voice in voices) {
      if (voice.voiceId == defaultVoiceId) {
        return voice;
      }
    }
    return voices.first;
  }

  @override
  Future<TtsVoice> getDefaultVoiceForLocale(String locale) async {
    final normalizedLocale = _normalizeLocale(locale);
    final scoped = await getAvailableVoices(locale: normalizedLocale);
    if (scoped.isNotEmpty) {
      for (final voice in scoped) {
        if (voice.isDefault) {
          return voice;
        }
      }
      for (final voice in scoped) {
        if (voice.voiceId == defaultVoiceId) {
          return voice;
        }
      }
      return scoped.first;
    }

    return getDefaultVoice();
  }

  @override
  Stream<TtsChunk> synthesize(
    TtsRequest request,
    SynthesisControl control,
    TtsAudioSpec resolvedFormat,
  ) async* {
    try {
      final response = await apiClient.send(
        buildApiRequest(request, resolvedFormat),
      );

      if (response.statusCode != 200) {
        final errorBytes = await _collectBytes(response.stream);
        throw OpenAiTransportException(
          statusCode: response.statusCode,
          message: parseErrorResponse(response.statusCode, errorBytes),
        );
      }

      final audioStream = parseSuccessResponse(
        response,
        request,
        resolvedFormat.format,
      );

      var sequence = 0;
      List<int>? pending;

      await for (final chunk in audioStream) {
        if (control.isCanceled) {
          return;
        }

        if (pending != null) {
          yield TtsChunk(
            requestId: request.requestId,
            sequenceNumber: sequence,
            bytes: Uint8List.fromList(pending),
            audioSpec: resolvedFormat,
            isLastChunk: false,
            timestamp: DateTime.now().toUtc(),
          );
          sequence++;
        }

        pending = chunk;
      }

      if (control.isCanceled) {
        return;
      }

      final lastBytes = pending ?? Uint8List(0);
      yield TtsChunk(
        requestId: request.requestId,
        sequenceNumber: sequence,
        bytes: Uint8List.fromList(lastBytes),
        audioSpec: resolvedFormat,
        isLastChunk: true,
        timestamp: DateTime.now().toUtc(),
      );
    } on OpenAiTransportException catch (error) {
      throw TtsError(
        code: mapStatusCode(error.statusCode),
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

  /// Builds the raw HTTP request sent by the API client.
  OpenAiApiRequest buildApiRequest(
    TtsRequest request,
    TtsAudioSpec resolvedFormat,
  ) {
    return OpenAiApiRequest.json(
      method: 'POST',
      endpoint: resolveEndpoint(request, resolvedFormat),
      headers: buildRequestHeaders(request, resolvedFormat),
      body: buildRequestBody(request, resolvedFormat),
    );
  }

  /// Override to route requests to a non-default endpoint.
  String? resolveEndpoint(TtsRequest request, TtsAudioSpec resolvedFormat) {
    return null;
  }

  /// Override to customise request headers for OpenAI-compatible providers.
  Map<String, String> buildRequestHeaders(
    TtsRequest request,
    TtsAudioSpec resolvedFormat,
  ) {
    final headers = <String, String>{
      'Content-Type': 'application/json',
    };
    if (apiKey.isNotEmpty) {
      headers['Authorization'] = 'Bearer $apiKey';
    }
    return headers;
  }

  /// Override to customise payload shape for compatible providers.
  String buildRequestBody(TtsRequest request, TtsAudioSpec resolvedFormat) {
    return jsonEncode({
      'model': model,
      'input': request.text,
      'voice': request.voice?.voiceId ?? defaultVoiceId,
      'response_format': mapFormat(resolvedFormat.format),
    });
  }

  /// Override if a provider expects different format tokens.
  String mapFormat(TtsAudioFormat format) {
    switch (format) {
      case TtsAudioFormat.pcm:
        return 'pcm';
      case TtsAudioFormat.mp3:
        return 'mp3';
      case TtsAudioFormat.wav:
        return 'wav';
      case TtsAudioFormat.opus:
        return 'opus';
      case TtsAudioFormat.aac:
        return 'aac';
    }
  }

  /// Override when success responses are wrapped in JSON envelopes.
  Stream<List<int>> parseSuccessResponse(
    http.StreamedResponse response,
    TtsRequest request,
    TtsAudioFormat resolvedFormat,
  ) {
    return response.stream;
  }

  /// Override to parse custom error envelope shapes.
  String parseErrorResponse(int statusCode, Uint8List bodyBytes) {
    return bodyBytes.isEmpty
        ? 'OpenAI request failed with status $statusCode.'
        : utf8.decode(bodyBytes, allowMalformed: true);
  }

  /// Maps an HTTP status code from the transport layer to a [TtsErrorCode].
  /// Override to adjust error classification for compatible engines that use
  /// non-standard status codes.
  TtsErrorCode mapStatusCode(int statusCode) {
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

  Future<Uint8List> _collectBytes(Stream<List<int>> stream) async {
    final builder = BytesBuilder(copy: false);
    await for (final data in stream) {
      builder.add(data);
    }
    return builder.takeBytes();
  }

  List<TtsVoice> _resolveVoices() {
    final override = voiceCatalogOverrides?[model];
    if (override != null) {
      return _withDefaultFallback(override);
    }
    final catalog = _builtInCatalog[model];
    if (catalog != null) {
      return _withDefaultFallback(catalog);
    }
    return _fallbackVoices();
  }

  List<TtsVoice> _withDefaultFallback(List<TtsVoice> discovered) {
    if (discovered.isEmpty) {
      return _fallbackVoices();
    }
    final hasDefault = discovered.any((voice) => voice.isDefault);
    if (hasDefault) {
      return discovered;
    }

    return discovered.map((voice) {
      if (voice.voiceId != defaultVoiceId) {
        return voice;
      }
      return TtsVoice(
        voiceId: voice.voiceId,
        locale: voice.locale,
        displayName: voice.displayName,
        isDefault: true,
      );
    }).toList(growable: false);
  }

  List<TtsVoice> _fallbackVoices() {
    return _fallbackVoiceIds.map((voiceId) {
      return TtsVoice(
        voiceId: voiceId,
        isDefault: voiceId == defaultVoiceId,
      );
    }).toList(growable: false);
  }

  String _normalizeLocale(String locale) {
    return locale.trim().replaceAll('_', '-').toLowerCase();
  }

  bool _localeMatches(String? voiceLocale, String normalizedLocale) {
    if (voiceLocale == null || voiceLocale.isEmpty) {
      return false;
    }
    final normalizedVoiceLocale = _normalizeLocale(voiceLocale);
    if (normalizedVoiceLocale == normalizedLocale) {
      return true;
    }
    final language = normalizedLocale.split('-').first;
    return normalizedVoiceLocale == language ||
        normalizedVoiceLocale.startsWith('$language-');
  }

  @override
  Future<void> dispose() async {}
}
