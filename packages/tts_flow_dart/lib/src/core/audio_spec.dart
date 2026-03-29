import 'package:tts_flow_dart/src/base/pcm_descriptor.dart';

enum TtsAudioFormat {
  /// raw interleaved PCM data,
  /// with format details specified in the [pcm] field of [TtsAudioSpec]
  pcm,

  /// mp3 frames, no ID3 v1/v2 tags
  mp3,

  /// opus packets in ogg container
  opus,

  /// aac frames with ADTS header
  aac,
}

extension TtsAudioFormatX on TtsAudioFormat {
  String get name {
    switch (this) {
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

  String get mimeType {
    switch (this) {
      case TtsAudioFormat.pcm:
        return 'audio/pcm';
      case TtsAudioFormat.mp3:
        return 'audio/mpeg';
      case TtsAudioFormat.opus:
        return 'audio/opus';
      case TtsAudioFormat.aac:
        return 'audio/aac';
    }
  }
}

/// Unified audio format specification carrying both the format type and optional PCM descriptor.
class TtsAudioSpec {
  const TtsAudioSpec.pcm(PcmDescriptor? pcm)
    : format = TtsAudioFormat.pcm,
      _pcm = pcm;

  const TtsAudioSpec.mp3() : format = TtsAudioFormat.mp3, _pcm = null;

  const TtsAudioSpec.opus() : format = TtsAudioFormat.opus, _pcm = null;

  const TtsAudioSpec.aac() : format = TtsAudioFormat.aac, _pcm = null;

  /// The audio format type (mp3, pcm, opus, aac)
  final TtsAudioFormat format;

  /// PCM descriptor (non-null only when format == TtsAudioFormat.pcm)
  final PcmDescriptor? _pcm;

  PcmDescriptor? get pcm => _pcm;

  /// Returns [pcm] if format is PCM; throws [StateError] otherwise.
  PcmDescriptor get requirePcm {
    if (format != TtsAudioFormat.pcm) {
      throw StateError('Expected PCM format, got $format');
    }
    if (_pcm == null) {
      throw StateError('PCM format specified but pcm descriptor is null');
    }
    return _pcm;
  }

  @override
  String toString() => 'TtsAudioSpec(format: $format, pcm: $_pcm)';

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is TtsAudioSpec &&
          runtimeType == other.runtimeType &&
          format == other.format &&
          _pcm == other._pcm;

  @override
  int get hashCode => format.hashCode ^ _pcm.hashCode;
}
