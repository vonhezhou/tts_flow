import 'dart:async';
import 'dart:typed_data';

import 'package:googleai_dart/googleai_dart.dart' as google;
import 'package:http/http.dart' as http;
import 'package:tts_flow_dart/tts_flow_dart.dart';

/// Single-speaker Gemini TTS, decoded by googleai_dart into 24 kHz PCM16LE.
///
/// Uses the Gemini 3.1 Flash TTS streamGenerateContent and voice schema.
/// Requests are not retried. Deadlines cover response headers and idle gaps
/// between HTTP chunks, rather than the total duration of synthesis.
class GeminiTtsEngine with TtsEngineDefaults implements TtsEngine {
  GeminiTtsEngine({
    required String apiKey,
    this.model = 'gemini-3.1-flash-tts-preview',
    this.defaultVoiceId = 'Kore',
    this.requestTimeout = const Duration(seconds: 45),
    http.Client? httpClient,
  }) : _httpClient = httpClient ?? http.Client(),
       _ownsHttpClient = httpClient == null {
    _client = google.GoogleAIClient(
      config: google.GoogleAIConfig.googleAI(
        authProvider: google.ApiKeyProvider(
          apiKey,
          placement: google.AuthPlacement.header,
        ),
        timeout: requestTimeout,
        retryPolicy: const google.RetryPolicy(maxRetries: 0),
      ),
      httpClient: _DeadlineClient(_httpClient, requestTimeout),
    );
  }

  final String model;
  final String defaultVoiceId;
  final Duration requestTimeout;
  final http.Client _httpClient;
  final bool _ownsHttpClient;
  late final google.GoogleAIClient _client;

  static const audioSpec = TtsAudioSpec.pcm(PcmDescriptor.s16Mono24KHz());

  @override
  String get engineId => 'gemini';
  @override
  int get maxInputCharacterCount => 0;
  @override
  bool get supportsStreaming => true;
  @override
  double get minSpeed => 0;
  @override
  double get maxSpeed => 0;
  @override
  Set<AudioCapability> get outAudioCapabilities => {
    PcmCapability(
      sampleRatesHz: {24000},
      bitsPerSample: {16},
      channels: {1},
      encodings: {PcmEncoding.signedInt},
    ),
  };

  // A small curated set of multilingual prebuilt voices; callers may also use
  // any other documented prebuilt voice ID in TtsRequest.voice.
  @override
  Future<List<TtsVoice>> getAvailableVoices({String? locale}) async => [
    await getDefaultVoice(),
    for (final id in ['Kore', 'Puck', 'Zephyr'])
      if (id != defaultVoiceId) TtsVoice(voiceId: id, displayName: id),
  ];
  @override
  Future<TtsVoice> getDefaultVoice() async => TtsVoice(
    voiceId: defaultVoiceId,
    displayName: defaultVoiceId,
    isDefault: true,
  );
  @override
  Future<TtsVoice> getDefaultVoiceForLocale(String locale) => getDefaultVoice();
  @override
  Future<void> init() async {}

  @override
  Stream<TtsChunk> synthesize(
    TtsRequest request,
    SynthesisControl control,
    TtsAudioSpec resolvedFormat,
  ) async* {
    if (resolvedFormat != audioSpec) {
      throw TtsError(
        code: TtsErrorCode.formatNegotiationFailed,
        message: 'Gemini TTS requires 24 kHz, 16-bit mono signed PCM.',
        requestKey: request.requestKey,
      );
    }
    if (control.isCanceled) return;
    var sequence = 0;
    Uint8List? pending;
    var stopped = false;
    try {
      final responses = _client.models.streamGenerateContent(
        model: model,
        request: google.GenerateContentRequest(
          contents: [google.Content.text(request.text)],
          generationConfig: google.GenerationConfig(
            responseModalities: [google.ResponseModality.audio],
            speechConfig: google.SpeechConfig.withVoice(
              request.voice?.voiceId ?? defaultVoiceId,
            ),
          ),
        ),
      );
      await for (final response in responses) {
        if (control.isCanceled) return;
        final candidates = response.candidates;
        if (candidates == null || candidates.isEmpty) continue;
        final candidate = candidates.first;
        final finish = candidate.finishReason;
        if (finish != null && finish != google.FinishReason.unspecified) {
          if (finish != google.FinishReason.stop) {
            throw const FormatException('Gemini did not finish normally.');
          }
          stopped = true;
        }
        for (final part in candidate.content?.parts ?? <google.Part>[]) {
          if (part is! google.InlineDataPart) continue;
          final blob = part.inlineData;
          final mime = blob.mimeType.toLowerCase().replaceAll(' ', '');
          final pieces = mime.split(';');
          if (pieces.first != 'audio/l16' ||
              !pieces.contains('rate=24000') ||
              pieces.any((p) => p.startsWith('codec=') && p != 'codec=pcm')) {
            throw const FormatException('Unexpected Gemini audio encoding.');
          }
          final bytes = Uint8List.fromList(blob.toBytes());
          if (bytes.isEmpty) continue;
          if (bytes.length.isOdd) {
            throw const FormatException('Incomplete Gemini PCM16 sample.');
          }
          if (pending != null) {
            yield _chunk(request, sequence++, pending, false);
          }
          pending = bytes;
        }
      }
      if (control.isCanceled) return;
      if (!stopped || pending == null) {
        throw const FormatException(
          'Gemini returned no complete audio stream.',
        );
      }
      yield _chunk(request, sequence, pending, true);
    } on TimeoutException {
      throw TtsError(
        code: TtsErrorCode.timeout,
        message: 'Gemini TTS request timed out.',
        requestKey: request.requestKey,
      );
    } on google.ApiException catch (error) {
      throw TtsError(
        code: switch (error.statusCode) {
          401 || 403 => TtsErrorCode.authFailed,
          408 || 504 => TtsErrorCode.timeout,
          429 || >= 500 => TtsErrorCode.networkError,
          _ => TtsErrorCode.invalidRequest,
        },
        message: 'Gemini TTS returned HTTP ${error.statusCode}.',
        requestKey: request.requestKey,
      );
    } on FormatException {
      throw TtsError(
        code: TtsErrorCode.unsupportedFormat,
        message: 'Gemini returned an invalid or incomplete PCM stream.',
        requestKey: request.requestKey,
      );
    } catch (_) {
      throw TtsError(
        code: TtsErrorCode.networkError,
        message: 'Gemini TTS request failed.',
        requestKey: request.requestKey,
      );
    }
  }

  TtsAudioChunk _chunk(
    TtsRequest request,
    int sequence,
    Uint8List bytes,
    bool last,
  ) => TtsAudioChunk(
    requestKey: request.requestKey,
    sequenceNumber: sequence,
    bytes: bytes,
    audioSpec: audioSpec,
    isLastChunk: last,
    timestamp: DateTime.now().toUtc(),
  );

  @override
  Future<void> dispose() async {
    _client.close();
    if (_ownsHttpClient) _httpClient.close();
  }
}

final class _DeadlineClient extends http.BaseClient {
  _DeadlineClient(this.delegate, this.deadline);
  final http.Client delegate;
  final Duration deadline;
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final response = await delegate.send(request).timeout(deadline);
    return http.StreamedResponse(
      response.stream.timeout(deadline),
      response.statusCode,
      headers: response.headers,
      contentLength: response.contentLength,
      request: response.request,
      isRedirect: response.isRedirect,
      persistentConnection: response.persistentConnection,
      reasonPhrase: response.reasonPhrase,
    );
  }
}
