import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:tts_flow_dart/src/base/pcm_descriptor.dart';
import 'package:tts_flow_dart/src/core/audio_capability.dart';
import 'package:tts_flow_dart/src/core/audio_spec.dart';
import 'package:tts_flow_dart/src/core/synthesis_control.dart';
import 'package:tts_flow_dart/src/core/tts_chunk.dart';
import 'package:tts_flow_dart/src/core/tts_engine.dart';
import 'package:tts_flow_dart/src/core/tts_request.dart';
import 'package:tts_flow_dart/src/core/tts_voice.dart';

final class SineTtsEngine with TtsEngineDefaults implements TtsEngine {
  SineTtsEngine({
    required this.engineId,
    required this.supportsStreaming,
    this.chunkCount = 1,
    this.chunkDelay = Duration.zero,
  }) : assert(chunkCount > 0);

  @override
  final String engineId;

  @override
  final int maxInputByteSize = 0;

  @override
  final bool supportsStreaming;

  @override
  Set<AudioCapability> get outAudioCapabilities => {
    PcmCapability(
      sampleRatesHz: {16000, 22050, 24000, 44100, 48000},
      bitsPerSample: {16},
      channels: {1, 2},
      encodings: {PcmEncoding.signedInt},
    ),
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
    return _voices
        .where((voice) {
          return _localeMatches(voice.locale, normalized);
        })
        .toList(growable: false);
  }

  @override
  Future<TtsVoice> getDefaultVoice() async {
    return _voices.firstWhere(
      (voice) => voice.isDefault,
      orElse: () => _voices.first,
    );
  }

  @override
  Future<TtsVoice> getDefaultVoiceForLocale(String locale) async {
    final normalized = _normalizeLocale(locale);
    final scoped = (await getAvailableVoices(locale: normalized));
    if (scoped.isNotEmpty) {
      return scoped.firstWhere(
        (voice) => voice.isDefault,
        orElse: () => scoped.first,
      );
    }
    return getDefaultVoice();
  }

  @override
  Stream<TtsChunk> synthesize(
    TtsRequest request,
    SynthesisControl control,
    TtsAudioSpec resolvedFormat,
  ) async* {
    final pcm = resolvedFormat.format == TtsAudioFormat.pcm
        ? resolvedFormat.requirePcm
        : const PcmDescriptor(
            sampleRateHz: 24000,
            bitsPerSample: 16,
            channels: 1,
          );

    const frequency = 440.0; // A4 tone
    const amplitude = 16384; // 50% of 16-bit signed max
    final wordCount = request.text.trim().split(RegExp(r'\s+')).length;
    final durationSeconds = math.max(0.1, wordCount * 0.3);
    final sampleCount = (pcm.sampleRateHz * durationSeconds).round();
    final sineBuffer = Int16List(sampleCount * pcm.channels);
    for (var s = 0; s < sampleCount; s++) {
      final value =
          (amplitude * math.sin(2 * math.pi * frequency * s / pcm.sampleRateHz))
              .round();
      for (var c = 0; c < pcm.channels; c++) {
        sineBuffer[s * pcm.channels + c] = value;
      }
    }

    final payload = sineBuffer.buffer.asUint8List();
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

      yield TtsAudioChunk(
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
  Future<void> init() async {}

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
