import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:tts_flow_dart/tts_flow_dart.dart';

import 'http_transport.dart';
import 'models.dart';
import 'retrying_transport.dart';
import 'transport.dart';

part 'openai_voice_catalog.dart';

class OpenAiTtsEngine with TtsEngineDefaults implements TtsEngine {
  OpenAiTtsEngine({
    required OpenAiApiClient apiClient,
    String engineId = 'openai',
    String defaultVoiceId = 'alloy',
    int nonStreamingChunkSizeBytes = 4096,
    String model = 'gpt-4o-mini-tts',
    String apiKey = '',
    Map<String, List<TtsVoice>>? voiceCatalogOverrides,
  }) : this._(
         apiClient: apiClient,
         engineId: engineId,
         defaultVoiceId: defaultVoiceId,
         nonStreamingChunkSizeBytes: nonStreamingChunkSizeBytes,
         model: model,
         apiKey: apiKey,
         voiceCatalogOverrides: voiceCatalogOverrides,
         ownsApiClient: false,
       );

  OpenAiTtsEngine._({
    required this.apiClient,
    required this.engineId,
    required this.defaultVoiceId,
    required this.nonStreamingChunkSizeBytes,
    required this.model,
    required this.apiKey,
    required this.voiceCatalogOverrides,
    required bool ownsApiClient,
  }) : _ownsApiClient = ownsApiClient;

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

    return OpenAiTtsEngine._(
      apiClient: apiClient,
      engineId: engineId,
      defaultVoiceId: defaultVoiceId,
      nonStreamingChunkSizeBytes: nonStreamingChunkSizeBytes,
      model: config.model,
      apiKey: config.apiKey,
      voiceCatalogOverrides: voiceCatalogOverrides,
      ownsApiClient: true,
    );
  }

  final OpenAiApiClient apiClient;
  @override
  final String engineId;

  /// The provider accepts at most 4096 user-visible input characters.
  @override
  final int maxInputCharacterCount = 4096;

  final String defaultVoiceId;
  final int nonStreamingChunkSizeBytes;
  final String model;
  final String apiKey;
  final Map<String, List<TtsVoice>>? voiceCatalogOverrides;
  final bool _ownsApiClient;

  @override
  bool get supportsStreaming => true;

  @override
  double get minSpeed => 0.25;

  @override
  double get maxSpeed => 4.0;

  @override
  Set<AudioCapability> get outAudioCapabilities => {
    const Mp3Capability(),
    const AacCapability(),
    const OpusCapability(),
    PcmCapability(
      sampleRatesHz: {_openAiPcmSampleRateHz},
      bitsPerSample: {_openAiPcmBitsPerSample},
      channels: {_openAiPcmChannels},
      encodings: {PcmEncoding.signedInt},
    ),
  };

  static const int _openAiPcmSampleRateHz = 24000;
  static const int _openAiPcmBitsPerSample = 16;
  static const int _openAiPcmChannels = 1;

  @override
  Future<List<TtsVoice>> getAvailableVoices({String? locale}) async {
    final voices = _resolveVoices();
    if (locale == null || locale.trim().isEmpty) {
      return voices;
    }

    final normalizedLocale = _normalizeLocale(locale);
    final scoped = voices
        .where((voice) {
          return _localeMatches(voice.locale, normalizedLocale);
        })
        .toList(growable: false);

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
          yield TtsAudioChunk(
            requestKey: request.requestKey,
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
      yield TtsAudioChunk(
        requestKey: request.requestKey,
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
        requestKey: request.requestKey,
        cause: error,
      );
    } catch (error) {
      throw TtsError(
        code: TtsErrorCode.networkError,
        message: 'OpenAI TTS request failed.',
        requestKey: request.requestKey,
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
    final headers = <String, String>{'Content-Type': 'application/json'};
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
      ...buildProsodyRequestArgs(request),
    });
  }

  /// Builds common runtime prosody controls for providers that accept
  /// OpenAI-compatible payloads.
  Map<String, Object> buildProsodyRequestArgs(TtsRequest request) {
    final args = <String, Object>{};
    final options = request.options;

    if (options?.speed != null && maxSpeed > minSpeed) {
      args['speed'] = options!.speed!;
    }
    if (options?.pitch != null && maxPitch > minPitch) {
      args['pitch'] = options!.pitch!;
    }
    if (options?.volume != null && maxVolume > minVolume) {
      args['volume'] = options!.volume!;
    }
    return args;
  }

  /// Override if a provider expects different format tokens.
  String mapFormat(TtsAudioFormat format) {
    switch (format) {
      case TtsAudioFormat.pcm:
        return 'pcm';
      case TtsAudioFormat.mp3:
        return 'mp3';
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

  List<TtsVoice> _resolveVoices() => _OpenAiVoiceCatalog(
    model: model,
    defaultVoiceId: defaultVoiceId,
    overrides: voiceCatalogOverrides,
  ).resolve();

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
  Future<void> init() async {}

  @override
  Future<void> dispose() async {
    if (!_ownsApiClient) {
      return;
    }
    final client = apiClient;
    if (client is OpenAiDisposableApiClient) {
      await client.dispose();
    }
  }
}
