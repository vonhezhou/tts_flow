/// Encoding type for PCM audio samples.
/// Maps to WAV format codes:
/// - signedInt: WAVE_FORMAT_PCM (typical 16/24-bit signed)
/// - unsignedInt: unsigned 8-bit PCM
/// - float: WAVE_FORMAT_IEEE_FLOAT (32/64-bit float)
enum PcmEncoding { signedInt, unsignedInt, float }

const int wavMinSampleRateHz = 1;
const int wavMaxSampleRateHz = 0xFFFFFFFF;
const int wavMinBitsPerSample = 1;
const int wavMaxBitsPerSample = 0xFFFF;
const int wavMinChannels = 1;
const int wavMaxChannels = 2;

/// Descriptor for PCM audio format, containing only fields exposed by WAV headers.
/// - Byte order: always little-endian (WAV standard, implicit)
/// - Layout: always interleaved (standard TTS convention, implicit)
class PcmDescriptor {
  const PcmDescriptor({
    required this.sampleRateHz,
    required this.bitsPerSample,
    required this.channels,
    this.encoding = PcmEncoding.signedInt,
  }) : assert(sampleRateHz >= wavMinSampleRateHz),
       assert(sampleRateHz <= wavMaxSampleRateHz),
       assert(bitsPerSample >= wavMinBitsPerSample),
       assert(bitsPerSample <= wavMaxBitsPerSample),
       assert(channels >= wavMinChannels),
       assert(channels <= wavMaxChannels);

  const PcmDescriptor.s16Mono24KHz()
    : this(
        sampleRateHz: 24000,
        bitsPerSample: 16,
        channels: 1,
        encoding: PcmEncoding.signedInt,
      );

  /// Sample rate in Hz (e.g., 24000, 44100)
  final int sampleRateHz;

  /// Bits per sample stored in the WAV header as an unsigned 16-bit integer.
  /// Common values are 8, 16, 24, 32, and 64.
  final int bitsPerSample;

  /// Number of channels.
  ///
  /// WAV stores this as an unsigned 16-bit integer, but this package limits
  /// support to mono and stereo for simplicity.
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
