import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:tts_flow_dart/tts_flow_dart.dart';

/// Configuration for the Azure AI Speech REST text-to-speech endpoint.
///
/// Create a Speech resource in [region] and pass one of its resource keys as
/// [subscriptionKey]. The key remains application-owned and is never stored by
/// this package.
final class AzureSpeechConfig {
  const AzureSpeechConfig({
    required this.subscriptionKey,
    required this.region,
    this.defaultVoiceId = 'zh-CN-XiaoxiaoNeural',
    this.defaultVoiceLocale = 'zh-CN',
    this.requestTimeout = const Duration(seconds: 30),
    this.userAgent = 'tts_flow_azure/0.1.0',
  });

  final String subscriptionKey;

  /// Azure Speech resource region, for example `eastasia`.
  final String region;
  final String defaultVoiceId;
  final String defaultVoiceLocale;
  final Duration requestTimeout;
  final String userAgent;

  String get synthesisEndpoint =>
      'https://${region.trim()}.tts.speech.microsoft.com/cognitiveservices/v1';

  String get voiceListEndpoint =>
      'https://${region.trim()}.tts.speech.microsoft.com/cognitiveservices/voices/list';
}

/// Azure AI Speech REST adapter that emits streamed MP3 response bytes.
///
/// Azure's REST API requires SSML and an `X-Microsoft-OutputFormat` header.
/// This engine deliberately advertises only MP3: Azure's PCM REST formats are
/// RIFF/WAV containers rather than the raw PCM required by `tts_flow_dart`.
class AzureSpeechTtsEngine with TtsEngineDefaults implements TtsEngine {
  AzureSpeechTtsEngine({
    required this.config,
    this.engineId = 'azure-speech',
    http.Client? httpClient,
  }) : _httpClient = httpClient ?? http.Client();

  final AzureSpeechConfig config;
  @override
  final String engineId;
  final http.Client _httpClient;

  List<TtsVoice>? _cachedVoices;

  @override
  int get maxInputCharacterCount => 0;

  @override
  bool get supportsStreaming => true;

  @override
  Set<AudioCapability> get outAudioCapabilities => const {Mp3Capability()};

  /// Azure SSML rate is represented as a percentage in the request.
  @override
  double get minSpeed => 0.5;

  @override
  double get maxSpeed => 2.0;

  @override
  Future<void> init() async {
    if (config.region.trim().isEmpty) {
      throw ArgumentError.value(config.region, 'region', 'Must not be empty.');
    }
  }

  @override
  Future<void> dispose() async {}

  @override
  Future<List<TtsVoice>> getAvailableVoices({String? locale}) async {
    final voices = await _loadVoices();
    if (locale == null || locale.trim().isEmpty) {
      return voices;
    }

    final normalized = _normalizeLocale(locale);
    final scoped = voices
        .where((voice) => _localeMatches(voice.locale, normalized))
        .toList(growable: false);
    return scoped.isEmpty ? voices : scoped;
  }

  @override
  Future<TtsVoice> getDefaultVoice() async {
    return TtsVoice(
      voiceId: config.defaultVoiceId,
      locale: config.defaultVoiceLocale,
      displayName: config.defaultVoiceId,
      isDefault: true,
    );
  }

  @override
  Future<TtsVoice> getDefaultVoiceForLocale(String locale) async {
    final voices = await getAvailableVoices(locale: locale);
    final configuredDefault = voices.where(
      (voice) => voice.voiceId == config.defaultVoiceId,
    );
    if (configuredDefault.isNotEmpty) {
      return configuredDefault.first;
    }
    return voices.first;
  }

  @override
  Stream<TtsChunk> synthesize(
    TtsRequest request,
    SynthesisControl control,
    TtsAudioSpec resolvedFormat,
  ) async* {
    if (resolvedFormat.format != TtsAudioFormat.mp3) {
      throw TtsError(
        code: TtsErrorCode.formatNegotiationFailed,
        message: 'Azure Speech REST adapter supports MP3 output only.',
        requestKey: request.requestKey,
      );
    }

    try {
      final response = await _sendSynthesisRequest(request);
      if (response.statusCode != 200) {
        final bytes = await _collect(response.stream);
        throw _AzureSpeechHttpException(
          response.statusCode,
          _errorMessage(bytes, response.statusCode),
        );
      }

      var sequence = 0;
      Uint8List? pending;
      await for (final bytes in response.stream) {
        if (control.isCanceled) {
          return;
        }
        if (pending != null) {
          yield _chunk(request, resolvedFormat, sequence++, pending, false);
        }
        pending = Uint8List.fromList(bytes);
      }
      if (!control.isCanceled) {
        yield _chunk(
          request,
          resolvedFormat,
          sequence,
          pending ?? Uint8List(0),
          true,
        );
      }
    } on _AzureSpeechHttpException catch (error) {
      throw TtsError(
        code: _mapStatus(error.statusCode),
        message: error.message,
        requestKey: request.requestKey,
        cause: error,
      );
    } catch (error) {
      throw TtsError(
        code: TtsErrorCode.networkError,
        message: 'Azure Speech TTS request failed.',
        requestKey: request.requestKey,
        cause: error,
      );
    }
  }

  Future<List<TtsVoice>> _loadVoices() async {
    final cached = _cachedVoices;
    if (cached != null) {
      return cached;
    }

    try {
      final response = await _httpClient
          .get(Uri.parse(config.voiceListEndpoint), headers: _authHeaders())
          .timeout(config.requestTimeout);
      if (response.statusCode != 200) {
        throw _AzureSpeechHttpException(
          response.statusCode,
          _errorMessage(response.bodyBytes, response.statusCode),
        );
      }

      final payload = jsonDecode(response.body) as List<Object?>;
      final voices = payload
          .whereType<Map<String, Object?>>()
          .map(_voiceFromJson)
          .whereType<TtsVoice>()
          .toList(growable: false);
      if (voices.isEmpty) {
        throw const _AzureSpeechHttpException(
          0,
          'Azure Speech returned no usable voices.',
        );
      }
      _cachedVoices = voices;
      return voices;
    } on TimeoutException {
      throw const _AzureSpeechHttpException(
        408,
        'Azure Speech request timed out.',
      );
    } on _AzureSpeechHttpException {
      rethrow;
    } catch (error) {
      throw _AzureSpeechHttpException(
        0,
        'Azure Speech voice-list request failed.',
        error,
      );
    }
  }

  TtsVoice? _voiceFromJson(Map<String, Object?> value) {
    final voiceId = value['ShortName'];
    if (voiceId is! String || voiceId.isEmpty) {
      return null;
    }
    final displayName = value['DisplayName'];
    final locale = value['Locale'];
    return TtsVoice(
      voiceId: voiceId,
      locale: locale is String ? locale : null,
      displayName: displayName is String ? displayName : voiceId,
      isDefault: voiceId == config.defaultVoiceId,
    );
  }

  Future<http.StreamedResponse> _sendSynthesisRequest(
    TtsRequest request,
  ) async {
    final httpRequest =
        http.Request('POST', Uri.parse(config.synthesisEndpoint))
          ..headers.addAll({
            ..._authHeaders(),
            'Content-Type': 'application/ssml+xml',
            'X-Microsoft-OutputFormat': 'audio-24khz-48kbitrate-mono-mp3',
            'User-Agent': config.userAgent,
          })
          ..body = _buildSsml(request);
    try {
      return await _httpClient.send(httpRequest).timeout(config.requestTimeout);
    } on TimeoutException {
      throw const _AzureSpeechHttpException(
        408,
        'Azure Speech request timed out.',
      );
    } catch (error) {
      throw _AzureSpeechHttpException(
        0,
        'Azure Speech network request failed.',
        error,
      );
    }
  }

  Map<String, String> _authHeaders() => {
    'Ocp-Apim-Subscription-Key': config.subscriptionKey,
  };

  String _buildSsml(TtsRequest request) {
    final voice = request.voice;
    final voiceId = voice?.voiceId ?? config.defaultVoiceId;
    final locale = voice?.locale ?? config.defaultVoiceLocale;
    final speed = request.options?.speed;
    final rate = speed == null ? null : '${(speed * 100).round()}%';
    final content = _escapeXml(request.text);
    final speech = rate == null
        ? content
        : '<prosody rate="$rate">$content</prosody>';
    return '<speak version="1.0" xml:lang="${_escapeXml(locale)}" '
        'xmlns="http://www.w3.org/2001/10/synthesis">'
        '<voice name="${_escapeXml(voiceId)}">$speech</voice>'
        '</speak>';
  }

  String _escapeXml(String input) => input
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;')
      .replaceAll('"', '&quot;')
      .replaceAll("'", '&apos;');

  Future<Uint8List> _collect(Stream<List<int>> stream) async {
    final builder = BytesBuilder(copy: false);
    await for (final bytes in stream) {
      builder.add(bytes);
    }
    return builder.takeBytes();
  }

  TtsAudioChunk _chunk(
    TtsRequest request,
    TtsAudioSpec spec,
    int sequence,
    Uint8List bytes,
    bool isLast,
  ) => TtsAudioChunk(
    requestKey: request.requestKey,
    sequenceNumber: sequence,
    bytes: bytes,
    audioSpec: spec,
    isLastChunk: isLast,
    timestamp: DateTime.now().toUtc(),
  );

  String _errorMessage(Uint8List bytes, int statusCode) {
    if (bytes.isEmpty) {
      return 'Azure Speech request failed with status $statusCode.';
    }
    return utf8.decode(bytes, allowMalformed: true);
  }

  TtsErrorCode _mapStatus(int statusCode) {
    if (statusCode == 401 || statusCode == 403) {
      return TtsErrorCode.authFailed;
    }
    if (statusCode == 408 || statusCode == 504) {
      return TtsErrorCode.timeout;
    }
    if (statusCode >= 500 || statusCode == 429 || statusCode == 0) {
      return TtsErrorCode.networkError;
    }
    return TtsErrorCode.internalError;
  }

  String _normalizeLocale(String value) =>
      value.trim().replaceAll('_', '-').toLowerCase();

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
}

final class _AzureSpeechHttpException implements Exception {
  const _AzureSpeechHttpException(this.statusCode, this.message, [this.cause]);

  final int statusCode;
  final String message;
  final Object? cause;
}
