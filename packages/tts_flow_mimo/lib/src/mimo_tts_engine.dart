import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:tts_flow_dart/tts_flow_dart.dart';

import 'mimo_sse_audio_decoder.dart';

/// A MiMo V2.5 TTS adapter using the OpenAI-compatible Chat Completions API.
///
/// MiMo streams Base64 encoded PCM16LE audio. This adapter exposes it as 24 kHz,
/// 16-bit mono PCM, which lets `tts_flow_dart` wrap it in WAV when needed.
class MimoTtsEngine with TtsEngineDefaults implements TtsEngine {
  MimoTtsEngine({
    required this.apiKey,
    this.model = 'mimo-v2.5-tts',
    this.engineId = 'mimo',
    this.defaultVoiceId = 'mimo_default',
    this.endpoint = 'https://api.xiaomimimo.com/v1/chat/completions',
    this.requestTimeout = const Duration(seconds: 30),
    http.Client? httpClient,
  }) : _httpClient = httpClient ?? http.Client();

  final String apiKey;
  final String model;
  @override
  final String engineId;
  final String defaultVoiceId;
  final String endpoint;
  final Duration requestTimeout;
  final http.Client _httpClient;
  static const _audioDecoder = MimoSseAudioDecoder();

  static const _pcmDescriptor = PcmDescriptor(
    sampleRateHz: 24000,
    bitsPerSample: 16,
    channels: 1,
  );

  @override
  int get maxInputCharacterCount => 0;

  @override
  bool get supportsStreaming => true;

  @override
  Set<AudioCapability> get outAudioCapabilities => {
    PcmCapability(
      sampleRatesHz: {_pcmDescriptor.sampleRateHz},
      bitsPerSample: {_pcmDescriptor.bitsPerSample},
      channels: {_pcmDescriptor.channels},
      encodings: {PcmEncoding.signedInt},
    ),
  };

  @override
  double get minSpeed => 0;

  @override
  double get maxSpeed => 0;

  static const _voices = <TtsVoice>[
    TtsVoice(
      voiceId: 'mimo_default',
      displayName: 'MiMo Default',
      isDefault: true,
    ),
    TtsVoice(voiceId: '冰糖', locale: 'zh', displayName: '冰糖'),
    TtsVoice(voiceId: '茉莉', locale: 'zh', displayName: '茉莉'),
    TtsVoice(voiceId: '苏打', locale: 'zh', displayName: '苏打'),
    TtsVoice(voiceId: '白桦', locale: 'zh', displayName: '白桦'),
    TtsVoice(voiceId: 'Mia', locale: 'en', displayName: 'Mia'),
    TtsVoice(voiceId: 'Chloe', locale: 'en', displayName: 'Chloe'),
    TtsVoice(voiceId: 'Milo', locale: 'en', displayName: 'Milo'),
    TtsVoice(voiceId: 'Dean', locale: 'en', displayName: 'Dean'),
  ];

  @override
  Future<List<TtsVoice>> getAvailableVoices({String? locale}) async {
    if (locale == null || locale.trim().isEmpty) return _voices;
    final language = locale
        .trim()
        .replaceAll('_', '-')
        .split('-')
        .first
        .toLowerCase();
    final scoped = _voices.where((voice) => voice.locale == language).toList();
    return scoped.isEmpty ? _voices : scoped;
  }

  @override
  Future<TtsVoice> getDefaultVoice() async => _voices.first;

  @override
  Future<TtsVoice> getDefaultVoiceForLocale(String locale) async {
    final voices = await getAvailableVoices(locale: locale);
    return voices.firstWhere(
      (voice) => voice.isDefault,
      orElse: () => voices.first,
    );
  }

  @override
  Stream<TtsChunk> synthesize(
    TtsRequest request,
    SynthesisControl control,
    TtsAudioSpec resolvedFormat,
  ) async* {
    if (resolvedFormat.format != TtsAudioFormat.pcm ||
        resolvedFormat.pcm != _pcmDescriptor) {
      throw TtsError(
        code: TtsErrorCode.formatNegotiationFailed,
        message: 'MiMo TTS requires 24 kHz, 16-bit mono signed PCM.',
        requestKey: request.requestKey,
      );
    }

    try {
      final response = await _send(request);
      if (response.statusCode != 200) {
        final bytes = await _collect(response.stream);
        throw _MimoHttpException(response.statusCode, _errorMessage(bytes));
      }

      var sequence = 0;
      Uint8List? pending;
      await for (final audio in _audioDecoder.decode(response.stream)) {
        if (control.isCanceled) return;
        if (pending != null) {
          yield _chunk(request, resolvedFormat, sequence++, pending, false);
        }
        pending = audio;
      }
      if (control.isCanceled) return;
      yield _chunk(
        request,
        resolvedFormat,
        sequence,
        pending ?? Uint8List(0),
        true,
      );
    } on _MimoHttpException catch (error) {
      throw TtsError(
        code: _mapStatus(error.statusCode),
        message: error.message,
        requestKey: request.requestKey,
        cause: error,
      );
    } catch (error) {
      throw TtsError(
        code: TtsErrorCode.networkError,
        message: 'MiMo TTS request failed.',
        requestKey: request.requestKey,
        cause: error,
      );
    }
  }

  Future<http.StreamedResponse> _send(TtsRequest request) async {
    final httpRequest = http.Request('POST', Uri.parse(endpoint))
      ..headers.addAll({
        'Content-Type': 'application/json',
        if (apiKey.isNotEmpty) 'Authorization': 'Bearer $apiKey',
      })
      ..body = jsonEncode(_payload(request));
    try {
      return await _httpClient.send(httpRequest).timeout(requestTimeout);
    } on TimeoutException {
      throw const _MimoHttpException(408, 'MiMo request timed out.');
    } catch (error) {
      throw _MimoHttpException(0, 'MiMo network request failed.', error);
    }
  }

  Map<String, Object?> _payload(TtsRequest request) {
    final params = request.params;
    final instruction = params['mimoInstruction'];
    final voiceDesign = params['mimoVoiceDesignPrompt'];
    final messages = <Map<String, String>>[];
    final userContent = model == 'mimo-v2.5-tts-voicedesign'
        ? voiceDesign as String? ?? ''
        : instruction as String?;
    if (userContent != null && userContent.isNotEmpty) {
      messages.add({'role': 'user', 'content': userContent});
    }
    messages.add({'role': 'assistant', 'content': request.text});
    return {
      'model': model,
      'messages': messages,
      'audio': {
        'format': 'pcm16',
        'voice': request.voice?.voiceId ?? defaultVoiceId,
        if (params['mimoOptimizeTextPreview'] is bool)
          'optimize_text_preview': params['mimoOptimizeTextPreview'],
      },
      'stream': true,
    };
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

  Future<Uint8List> _collect(Stream<List<int>> stream) async {
    final builder = BytesBuilder(copy: false);
    await for (final bytes in stream) {
      builder.add(bytes);
    }
    return builder.takeBytes();
  }

  String _errorMessage(Uint8List bytes) {
    if (bytes.isEmpty) return 'MiMo request failed.';
    try {
      final body = jsonDecode(utf8.decode(bytes)) as Map<String, Object?>;
      final error = body['error'];
      if (error is Map<String, Object?> && error['message'] is String) {
        return error['message']! as String;
      }
    } catch (_) {}
    return utf8.decode(bytes, allowMalformed: true);
  }

  TtsErrorCode _mapStatus(int status) {
    if (status == 401 || status == 403) return TtsErrorCode.authFailed;
    if (status == 408 || status == 504) return TtsErrorCode.timeout;
    if (status >= 500 || status == 0) return TtsErrorCode.networkError;
    return TtsErrorCode.internalError;
  }

  @override
  Future<void> init() async {}

  @override
  Future<void> dispose() async {
    _httpClient.close();
  }
}

final class _MimoHttpException implements Exception {
  const _MimoHttpException(this.statusCode, this.message, [this.cause]);
  final int statusCode;
  final String message;
  final Object? cause;
}
