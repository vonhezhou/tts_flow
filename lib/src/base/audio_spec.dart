import 'package:tts_flow_dart/src/base/pcm_descriptor.dart';

enum TtsAudioFormat { pcm, mp3, wav, opus, aac }

/// Unified audio format specification carrying both the format type and optional PCM descriptor.
class TtsAudioSpec {
  const TtsAudioSpec({required this.format, this.pcm});

  /// The audio format type (mp3, pcm, wav, opus, aac)
  final TtsAudioFormat format;

  /// PCM descriptor (non-null only when format == TtsAudioFormat.pcm)
  final PcmDescriptor? pcm;

  /// Returns [pcm] if format is PCM; throws [StateError] otherwise.
  PcmDescriptor get requirePcm {
    if (format != TtsAudioFormat.pcm) {
      throw StateError('Expected PCM format, got $format');
    }
    if (pcm == null) {
      throw StateError('PCM format specified but pcm descriptor is null');
    }
    return pcm!;
  }

  @override
  String toString() => 'TtsAudioSpec(format: $format, pcm: $pcm)';

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is TtsAudioSpec &&
          runtimeType == other.runtimeType &&
          format == other.format &&
          pcm == other.pcm;

  @override
  int get hashCode => format.hashCode ^ pcm.hashCode;
}
