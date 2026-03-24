import 'dart:typed_data';

enum TtsAudioFormat { pcm, mp3, wav, opus, aac }

enum TtsRequestState { queued, running, completed, failed, stopped, canceled }

/// Encoding type for PCM audio samples.
/// Maps to WAV format codes:
/// - signedInt: WAVE_FORMAT_PCM (typical 16/24-bit signed)
/// - unsignedInt: unsigned 8-bit PCM
/// - float: WAVE_FORMAT_IEEE_FLOAT (32/64-bit float)
enum PcmEncoding { signedInt, unsignedInt, float }

/// Descriptor for PCM audio format, containing only fields exposed by WAV headers.
/// - Byte order: always little-endian (WAV standard, implicit)
/// - Layout: always interleaved (standard TTS convention, implicit)
class PcmDescriptor {
  const PcmDescriptor({
    required this.sampleRateHz,
    required this.bitsPerSample,
    required this.channels,
    this.encoding = PcmEncoding.signedInt,
  });

  /// Sample rate in Hz (e.g., 24000, 44100)
  final int sampleRateHz;

  /// Bits per sample: 8, 16, 24, 32, or 64
  final int bitsPerSample;

  /// Number of channels: 1 (mono), 2 (stereo), etc.
  final int channels;

  /// Sample encoding type
  final PcmEncoding encoding;

  @override
  String toString() =>
      'PcmDescriptor(sampleRateHz: $sampleRateHz, bitsPerSample: $bitsPerSample, channels: $channels, encoding: $encoding)';

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is PcmDescriptor &&
          runtimeType == other.runtimeType &&
          sampleRateHz == other.sampleRateHz &&
          bitsPerSample == other.bitsPerSample &&
          channels == other.channels &&
          encoding == other.encoding;

  @override
  int get hashCode =>
      sampleRateHz.hashCode ^
      bitsPerSample.hashCode ^
      channels.hashCode ^
      encoding.hashCode;
}

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

/// Capability declaration used during format/spec negotiation.
sealed class AudioCapability {
  const AudioCapability({required this.format});

  final TtsAudioFormat format;

  bool supports(TtsAudioSpec spec) {
    if (spec.format != format) {
      return false;
    }
    return true;
  }
}

/// Capability for non-PCM formats where only the format value is needed.
final class SimpleFormatCapability extends AudioCapability {
  const SimpleFormatCapability({required super.format});
}

/// Capability for PCM format that constrains descriptor fields.
final class PcmCapability extends AudioCapability {
  PcmCapability({
    required Set<int> sampleRatesHz,
    required Set<int> bitsPerSample,
    required Set<int> channels,
    required Set<PcmEncoding> encodings,
  })  : sampleRatesHz = Set.unmodifiable(sampleRatesHz),
        bitsPerSample = Set.unmodifiable(bitsPerSample),
        channels = Set.unmodifiable(channels),
        encodings = Set.unmodifiable(encodings),
        super(format: TtsAudioFormat.pcm) {
    if (sampleRatesHz.isEmpty) {
      throw ArgumentError.value(
        sampleRatesHz,
        'sampleRatesHz',
        'Must not be empty.',
      );
    }
    if (bitsPerSample.isEmpty) {
      throw ArgumentError.value(
        bitsPerSample,
        'bitsPerSample',
        'Must not be empty.',
      );
    }
    if (channels.isEmpty) {
      throw ArgumentError.value(channels, 'channels', 'Must not be empty.');
    }
    if (encodings.isEmpty) {
      throw ArgumentError.value(encodings, 'encodings', 'Must not be empty.');
    }
  }

  final Set<int> sampleRatesHz;
  final Set<int> bitsPerSample;
  final Set<int> channels;
  final Set<PcmEncoding> encodings;

  @override
  bool supports(TtsAudioSpec spec) {
    if (!super.supports(spec)) {
      return false;
    }
    final pcm = spec.pcm;
    if (pcm == null) {
      return false;
    }
    return sampleRatesHz.contains(pcm.sampleRateHz) &&
        bitsPerSample.contains(pcm.bitsPerSample) &&
        channels.contains(pcm.channels) &&
        encodings.contains(pcm.encoding);
  }

  @override
  String toString() {
    return 'PcmCapability(sampleRatesHz: $sampleRatesHz, bitsPerSample: $bitsPerSample, channels: $channels, encodings: $encodings)';
  }

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        other is PcmCapability &&
            _sameIntSet(sampleRatesHz, other.sampleRatesHz) &&
            _sameIntSet(bitsPerSample, other.bitsPerSample) &&
            _sameIntSet(channels, other.channels) &&
            _sameEncodingSet(encodings, other.encodings);
  }

  @override
  int get hashCode => Object.hash(
        Object.hashAll(sampleRatesHz.toList()..sort()),
        Object.hashAll(bitsPerSample.toList()..sort()),
        Object.hashAll(channels.toList()..sort()),
        Object.hashAll(encodings.toList()..sort((a, b) => a.index - b.index)),
      );
}

bool _sameIntSet(Set<int> a, Set<int> b) {
  if (a.length != b.length) {
    return false;
  }
  for (final value in a) {
    if (!b.contains(value)) {
      return false;
    }
  }
  return true;
}

bool _sameEncodingSet(Set<PcmEncoding> a, Set<PcmEncoding> b) {
  if (a.length != b.length) {
    return false;
  }
  for (final value in a) {
    if (!b.contains(value)) {
      return false;
    }
  }
  return true;
}

/// A class representing a TTS voice with its associated properties.
class TtsVoice {
  const TtsVoice({required this.voiceId});

  final String voiceId;
}

class TtsOptions {
  const TtsOptions({
    this.speed,
    this.pitch,
    this.volume,
    this.sampleRateHz,
    this.timeout,
  });

  final double? speed;
  final double? pitch;
  final double? volume;
  final int? sampleRateHz;
  final Duration? timeout;
}

class TtsRequest {
  const TtsRequest({
    required this.requestId,
    required this.text,
    this.voice,
    this.preferredFormat,
    this.options,
    this.params = const {},
  });

  final String requestId;
  final String text;
  final TtsVoice? voice;
  final TtsAudioFormat? preferredFormat;
  final TtsOptions? options;
  final Map<String, Object> params;
}

class TtsChunk {
  const TtsChunk({
    required this.requestId,
    required this.sequenceNumber,
    required this.bytes,
    required this.audioSpec,
    required this.isLastChunk,
    required this.timestamp,
  });

  final String requestId;
  final int sequenceNumber;
  final Uint8List bytes;
  final TtsAudioSpec audioSpec;
  final bool isLastChunk;
  final DateTime timestamp;
}
