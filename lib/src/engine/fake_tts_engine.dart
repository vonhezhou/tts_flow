import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import '../core/tts_contracts.dart';
import '../core/tts_models.dart';

final class FakeTtsEngine implements TtsEngine {
  FakeTtsEngine({
    required this.engineId,
    required this.supportsStreaming,
    this.chunkCount = 1,
    this.chunkDelay = Duration.zero,
  }) : assert(chunkCount > 0);

  @override
  final String engineId;

  @override
  final bool supportsStreaming;

  @override
  Set<AudioCapability> get supportedCapabilities => {
        PcmCapability(
          sampleRatesHz: {16000, 22050, 24000, 44100, 48000},
          bitsPerSample: {16},
          channels: {1, 2},
          encodings: {PcmEncoding.signedInt},
        ),
        const SimpleFormatCapability(format: TtsAudioFormat.wav),
        const SimpleFormatCapability(format: TtsAudioFormat.mp3),
      };

  final int chunkCount;
  final Duration chunkDelay;

  static const List<TtsVoice> _voices = [
    TtsVoice(
      voiceId: 'fake-en-us-1',
      locale: 'en-US',
      displayName: 'Fake US English',
      isDefault: true,
    ),
    TtsVoice(
      voiceId: 'fake-en-gb-1',
      locale: 'en-GB',
      displayName: 'Fake UK English',
    ),
    TtsVoice(
      voiceId: 'fake-es-es-1',
      locale: 'es-ES',
      displayName: 'Fake Spanish',
    ),
  ];

  @override
  Future<List<TtsVoice>> getAvailableVoices({String? locale}) async {
    if (locale == null || locale.trim().isEmpty) {
      return _voices;
    }
    final normalized = _normalizeLocale(locale);
    return _voices.where((voice) {
      return _localeMatches(voice.locale, normalized);
    }).toList(growable: false);
  }

  @override
  Future<TtsVoice> getDefaultVoice() async {
    return _voices.firstWhere((voice) => voice.isDefault,
        orElse: () => _voices.first);
  }

  @override
  Future<TtsVoice> getDefaultVoiceForLocale(String locale) async {
    final normalized = _normalizeLocale(locale);
    final scoped = (await getAvailableVoices(locale: normalized));
    if (scoped.isNotEmpty) {
      return scoped.firstWhere((voice) => voice.isDefault,
          orElse: () => scoped.first);
    }
    return getDefaultVoice();
  }

  @override
  Stream<TtsChunk> synthesize(
    TtsRequest request,
    SynthesisControl control,
    TtsAudioSpec resolvedFormat,
  ) async* {
    final payload = utf8.encode(request.text);
    final total = payload.length;
    final size = (total / chunkCount).ceil();

    for (var i = 0; i < chunkCount; i++) {
      if (control.isCanceled) {
        break;
      }

      final start = i * size;
      if (start >= total) {
        break;
      }
      final end = (start + size > total) ? total : start + size;
      final chunkBytes = Uint8List.fromList(payload.sublist(start, end));

      if (chunkDelay > Duration.zero) {
        await Future<void>.delayed(chunkDelay);
      }

      yield TtsChunk(
        requestId: request.requestId,
        sequenceNumber: i,
        bytes: chunkBytes,
        audioSpec: resolvedFormat,
        isLastChunk: end >= total,
        timestamp: DateTime.now().toUtc(),
      );
    }
  }

  @override
  Future<void> dispose() async {}

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
}
