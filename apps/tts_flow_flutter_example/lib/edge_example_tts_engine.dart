import 'dart:async';
import 'dart:typed_data';

import 'package:dart_edge_tts/dart_edge_tts.dart' as edge;
import 'package:tts_flow_dart/tts_flow_dart.dart';

/// 非正式 Edge 接口仅用于示例，不属于框架维护的 Provider。
final class EdgeExampleTtsEngine with TtsEngineDefaults implements TtsEngine {
  EdgeExampleTtsEngine({edge.EdgeTts? client})
    : _client = client ?? edge.EdgeTts();

  final edge.EdgeTts _client;
  List<edge.Voice> _voices = const [];
  bool _disposed = false;

  @override
  String get engineId => 'example-edge';
  @override
  bool get supportsStreaming => true;
  @override
  int get maxInputCharacterCount => 0;
  @override
  Set<AudioCapability> get outAudioCapabilities => {const Mp3Capability()};
  @override
  double get minVolume => 0;
  @override
  double get maxVolume => 1;
  @override
  double get minSpeed => 0.5;
  @override
  double get maxSpeed => 2;
  @override
  double get minPitch => 0.5;
  @override
  double get maxPitch => 1.5;

  @override
  Future<void> init() async {
    final voices = await _client.listVoices().timeout(
      const Duration(seconds: 20),
    );
    if (_disposed) throw StateError('Edge example engine was disposed');
    if (voices.isEmpty) throw StateError('Edge returned no voices');
    _voices = voices;
  }

  TtsVoice _voice(edge.Voice voice) => TtsVoice(
    voiceId: voice.shortName,
    locale: voice.locale,
    displayName: voice.localName.isNotEmpty ? voice.localName : voice.shortName,
    isDefault: voice.shortName == 'zh-CN-XiaoxiaoNeural',
  );

  @override
  Future<List<TtsVoice>> getAvailableVoices({String? locale}) async {
    final voices = _voices.map(_voice).toList();
    if (locale == null || locale.isEmpty) return voices;
    final normalized = locale.replaceAll('_', '-').toLowerCase();
    final exact = voices
        .where((v) => v.locale?.toLowerCase() == normalized)
        .toList();
    if (exact.isNotEmpty) return exact;
    return voices
        .where(
          (v) =>
              v.locale!.toLowerCase().split('-').first ==
              normalized.split('-').first,
        )
        .toList();
  }

  @override
  Future<TtsVoice> getDefaultVoice() async {
    final voices = await getAvailableVoices();
    return voices.firstWhere((v) => v.isDefault, orElse: () => voices.first);
  }

  @override
  Future<TtsVoice> getDefaultVoiceForLocale(String locale) async {
    final voices = await getAvailableVoices(locale: locale);
    return voices.isEmpty ? getDefaultVoice() : voices.first;
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
        message: 'The Edge example emits MP3 only.',
        requestKey: request.requestKey,
      );
    }
    if (control.isCanceled) return;
    final voiceId = request.voice?.voiceId ?? (await getDefaultVoice()).voiceId;
    final voice = _voices.where((v) => v.shortName == voiceId).firstOrNull;
    if (voice == null) {
      throw TtsError(
        code: TtsErrorCode.invalidRequest,
        message: 'Unknown Edge voice.',
        requestKey: request.requestKey,
      );
    }
    final events = StreamIterator(
      _client
          .stream(
            edge.TtsUtterance(id: request.requestKey, text: request.text),
            voice: voice,
            options: edge.TtsOptions(
              rate: request.options?.speed ?? 1,
              volume: request.options?.volume ?? 1,
              pitch: request.options?.pitch ?? 1,
            ),
          )
          .timeout(const Duration(seconds: 30)),
    );
    final canceled = Completer<bool>();
    // SynthesisControl 没有通知流；轮询只负责中断等待，不改写音频到达时间。
    final cancellation = Timer.periodic(const Duration(milliseconds: 50), (
      timer,
    ) {
      if (control.isCanceled) {
        timer.cancel();
        canceled.complete(false);
      }
    });
    var sequence = 0;
    Uint8List? pending;
    var completed = false;
    TtsAudioChunk chunk(Uint8List bytes, bool last) => TtsAudioChunk(
      requestKey: request.requestKey,
      sequenceNumber: sequence++,
      bytes: bytes,
      audioSpec: resolvedFormat,
      isLastChunk: last,
      timestamp: DateTime.now().toUtc(),
    );
    try {
      while (await Future.any([events.moveNext(), canceled.future])) {
        if (control.isCanceled) return;
        final event = events.current;
        if (event is edge.TtsAudioChunk && event.bytes.isNotEmpty) {
          if (pending != null) yield chunk(pending, false);
          pending = event.bytes;
        } else if (event is edge.TtsUtteranceCompleted) {
          completed = true;
        }
      }
      if (control.isCanceled) return;
      if (!completed || pending == null) {
        throw StateError('Edge returned incomplete or empty audio');
      }
      yield chunk(pending, true);
    } catch (error) {
      if (control.isCanceled) return;
      throw TtsError(
        code: TtsErrorCode.networkError,
        message: 'Experimental Edge synthesis failed. Try another source.',
        requestKey: request.requestKey,
        cause: error,
      );
    } finally {
      cancellation.cancel();
      await events.cancel();
    }
  }

  @override
  Future<void> dispose() async {
    _disposed = true;
    await _client.close();
  }
}
