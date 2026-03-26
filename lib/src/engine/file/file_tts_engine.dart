import 'dart:async';
import 'dart:typed_data';

import 'package:tts_flow_dart/src/core/audio_capability.dart';
import 'package:tts_flow_dart/src/core/audio_spec.dart';
import 'package:tts_flow_dart/src/core/synthesis_control.dart';
import 'package:tts_flow_dart/src/core/tts_chunk.dart';
import 'package:tts_flow_dart/src/core/tts_engine.dart';
import 'package:tts_flow_dart/src/core/tts_errors.dart';
import 'package:tts_flow_dart/src/core/tts_request.dart';
import 'package:tts_flow_dart/src/core/tts_voice.dart';
import 'package:tts_flow_dart/src/engine/file/file_content_provider.dart';

/// A deterministic engine that streams bytes from a [FileContentProvider]
/// regardless of request text.
final class FileTtsEngine implements TtsEngine {
  FileTtsEngine({
    required this.engineId,
    required this.provider,
    this.chunkSizeBytes = 4096,
    this.maxBytesPerSecond,
    this.supportsStreaming = true,
    List<TtsVoice>? voices,
  })  : assert(chunkSizeBytes > 0),
        _voices = List.unmodifiable(
          (voices == null || voices.isEmpty)
              ? const [
                  TtsVoice(
                    voiceId: 'file-engine-default',
                    locale: 'und',
                    displayName: 'File Engine Default',
                    isDefault: true,
                  ),
                ]
              : voices,
        ) {
    final bytesPerSecond = maxBytesPerSecond;
    if (bytesPerSecond != null && bytesPerSecond <= 0) {
      throw ArgumentError.value(
        maxBytesPerSecond,
        'maxBytesPerSecond',
        'Must be greater than zero when provided.',
      );
    }
  }

  @override
  final String engineId;

  final FileContentProvider provider;

  TtsAudioSpec get audioSpec => provider.audioSpec;

  final int chunkSizeBytes;
  final int? maxBytesPerSecond;

  @override
  final bool supportsStreaming;

  final List<TtsVoice> _voices;

  @override
  Set<AudioCapability> get supportedCapabilities =>
      provider.supportedCapabilities;

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
    final scoped = await getAvailableVoices(locale: normalized);
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
    if (!supportsSpec(resolvedFormat)) {
      throw TtsError(
        code: TtsErrorCode.unsupportedFormat,
        message: 'Resolved audio spec is not supported by this provider: '
            '$resolvedFormat',
        requestId: request.requestId,
      );
    }

    final stopwatch = Stopwatch()..start();
    var sequence = 0;
    var sentBytes = 0;
    Uint8List? pendingChunk;

    await for (final chunkBytes in provider.readChunks(chunkSizeBytes)) {
      if (control.isCanceled) {
        break;
      }

      final bytesPerSecond = maxBytesPerSecond;
      if (bytesPerSecond != null) {
        final afterChunkBytes = sentBytes + chunkBytes.length;
        final expectedElapsedMicros =
            ((afterChunkBytes * Duration.microsecondsPerSecond) /
                    bytesPerSecond)
                .ceil();
        final waitMicros =
            expectedElapsedMicros - stopwatch.elapsedMicroseconds;
        if (waitMicros > 0) {
          await Future<void>.delayed(Duration(microseconds: waitMicros));
        }
      }

      if (pendingChunk != null) {
        yield TtsChunk(
          requestId: request.requestId,
          sequenceNumber: sequence,
          bytes: pendingChunk,
          audioSpec: resolvedFormat,
          isLastChunk: false,
          timestamp: DateTime.now().toUtc(),
        );
        sequence += 1;
      }

      pendingChunk = chunkBytes;
      sentBytes += chunkBytes.length;
    }

    if (pendingChunk != null && !control.isCanceled) {
      yield TtsChunk(
        requestId: request.requestId,
        sequenceNumber: sequence,
        bytes: pendingChunk,
        audioSpec: resolvedFormat,
        isLastChunk: true,
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
