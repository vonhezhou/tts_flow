import 'dart:typed_data';

/// ADTS sample-rate table (ISO 14496-3, Table 4.82).
const _kSampleRateTable = [
  96000, 88200, 64000, 48000, 44100, 32000, //
  24000, 22050, 16000, 12000, 11025, 8000, 7350,
];

/// Minimal ADTS frame header carrying the fields relevant for append
/// validation: sampling frequency index and channel configuration.
///
/// ADTS is a self-framing format; each AAC raw frame is preceded by a 7-byte
/// (no CRC) or 9-byte (with CRC) header that embeds these fields.
final class AdtsFrameHeader {
  const AdtsFrameHeader({
    required this.samplingFrequencyIndex,
    required this.channelConfig,
  });

  /// Index into the ADTS sample-rate table (0–12). Use [sampleRateHz] for the
  /// decoded value. Indices 13–15 are reserved by the standard.
  final int samplingFrequencyIndex;

  /// Raw ADTS channel configuration field (0–7).
  final int channelConfig;

  /// Decoded sample rate in Hz, or `null` when the index is reserved (13–15).
  int? get sampleRateHz {
    if (samplingFrequencyIndex >= _kSampleRateTable.length) return null;
    return _kSampleRateTable[samplingFrequencyIndex];
  }

  /// Nominal channel count derived from [channelConfig]:
  ///   - 0 → null (defined in the bitstream, not determinable from header)
  ///   - 1 → 1 (mono)
  ///   - 2 → 2 (stereo)
  ///   - 3–6 → 3–6 (multi-channel)
  ///   - 7 → 8 (7.1)
  int? get channelCount {
    if (channelConfig == 0) return null;
    if (channelConfig == 7) return 8;
    return channelConfig;
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AdtsFrameHeader &&
          runtimeType == other.runtimeType &&
          samplingFrequencyIndex == other.samplingFrequencyIndex &&
          channelConfig == other.channelConfig;

  @override
  int get hashCode => samplingFrequencyIndex.hashCode ^ channelConfig.hashCode;

  /// Parses the first valid ADTS header found in [bytes].
  ///
  /// Throws [FormatException] when no valid sync word is detected.
  static AdtsFrameHeader parse(Uint8List bytes) {
    final header = tryParse(bytes);
    if (header == null) {
      throw const FormatException(
        'Invalid AAC data: no valid ADTS frame header found.',
      );
    }
    return header;
  }

  /// Scans [bytes] for an ADTS sync word (0xFFF) and returns the parsed
  /// header fields, or `null` when none is found.
  ///
  /// Requires at least 7 bytes starting at the sync position.
  static AdtsFrameHeader? tryParse(Uint8List bytes) {
    for (var i = 0; i <= bytes.length - 7; i++) {
      if (bytes[i] != 0xFF) continue;
      if ((bytes[i + 1] & 0xF0) != 0xF0) continue;

      final byte2 = bytes[i + 2];
      final byte3 = bytes[i + 3];

      // Sampling frequency index occupies bits 5–2 of byte 2.
      final sfi = (byte2 >> 2) & 0x0F;

      // Channel configuration is split: MSB is bit 0 of byte 2,
      // lower 2 bits are bits 7–6 of byte 3.
      final channelConf = ((byte2 & 0x01) << 2) | ((byte3 >> 6) & 0x03);

      return AdtsFrameHeader(
        samplingFrequencyIndex: sfi,
        channelConfig: channelConf,
      );
    }
    return null;
  }
}
