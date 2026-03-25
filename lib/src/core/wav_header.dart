import 'dart:typed_data';

import 'tts_models.dart';

/// Canonical 44-byte RIFF/WAVE header model for PCM-compatible audio streams.
class WavHeader {
  const WavHeader({
    required this.sampleRateHz,
    required this.bitsPerSample,
    required this.channels,
    required this.dataLengthBytes,
    this.encoding = PcmEncoding.signedInt,
  })  : assert(sampleRateHz > 0),
        assert(sampleRateHz <= wavMaxSampleRateHz),
        assert(bitsPerSample >= wavMinBitsPerSample),
        assert(bitsPerSample <= wavMaxBitsPerSample),
        assert(channels >= wavMinChannels),
        assert(channels <= wavMaxChannels),
        assert(dataLengthBytes >= 0);

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

  /// Size in bytes of PCM payload following this header.
  final int dataLengthBytes;

  /// Sample encoding type.
  final PcmEncoding encoding;

  int get blockAlign => ((channels * bitsPerSample) + 7) ~/ 8;

  int get byteRate => sampleRateHz * blockAlign;

  /// Parses a binary RIFF/WAVE header into a [WavHeader].
  ///
  /// Supports canonical 44-byte WAV headers with `fmt ` chunk size 16 for:
  /// - WAVE_FORMAT_PCM (1)
  /// - WAVE_FORMAT_IEEE_FLOAT (3)
  static WavHeader parse(Uint8List headerBytes) {
    if (headerBytes.length < 44) {
      throw const FormatException(
        'Invalid WAV header: expected at least 44 bytes.',
      );
    }

    bool asciiAt(int offset, String value) {
      for (var i = 0; i < value.length; i++) {
        if (headerBytes[offset + i] != value.codeUnitAt(i)) {
          return false;
        }
      }
      return true;
    }

    if (!asciiAt(0, 'RIFF') || !asciiAt(8, 'WAVE')) {
      throw const FormatException('Invalid WAV header: missing RIFF/WAVE.');
    }

    if (!asciiAt(12, 'fmt ')) {
      throw const FormatException('Invalid WAV header: missing fmt chunk.');
    }

    if (!asciiAt(36, 'data')) {
      throw const FormatException('Invalid WAV header: missing data chunk.');
    }

    final data = ByteData.sublistView(headerBytes);
    final fmtChunkSize = data.getUint32(16, Endian.little);
    if (fmtChunkSize < 16) {
      throw const FormatException(
          'Invalid WAV header: fmt chunk is too small.');
    }

    final formatCode = data.getUint16(20, Endian.little);
    final channels = data.getUint16(22, Endian.little);
    final sampleRateHz = data.getUint32(24, Endian.little);
    final bitsPerSample = data.getUint16(34, Endian.little);
    final dataLengthBytes = data.getUint32(40, Endian.little);

    if (channels == 0 || sampleRateHz == 0 || bitsPerSample == 0) {
      throw const FormatException('Invalid WAV header: invalid audio fields.');
    }

    final pcmEncoding = switch (formatCode) {
      1 => bitsPerSample == 8 ? PcmEncoding.unsignedInt : PcmEncoding.signedInt,
      3 => PcmEncoding.float,
      _ => throw FormatException(
          'Unsupported WAV format code: $formatCode. Only PCM(1) and IEEE float(3) are supported.',
        ),
    };

    return WavHeader(
      sampleRateHz: sampleRateHz,
      bitsPerSample: bitsPerSample,
      channels: channels,
      dataLengthBytes: dataLengthBytes,
      encoding: pcmEncoding,
    );
  }

  /// Creates a [WavHeader] from a [PcmDescriptor] and payload size.
  factory WavHeader.fromPcmDescriptor(
    PcmDescriptor descriptor, {
    required int dataLengthBytes,
  }) {
    return WavHeader(
      sampleRateHz: descriptor.sampleRateHz,
      bitsPerSample: descriptor.bitsPerSample,
      channels: descriptor.channels,
      encoding: descriptor.encoding,
      dataLengthBytes: dataLengthBytes,
    );
  }

  /// Returns this header's PCM descriptor view.
  PcmDescriptor toPcmDescriptor() {
    return PcmDescriptor(
      sampleRateHz: sampleRateHz,
      bitsPerSample: bitsPerSample,
      channels: channels,
      encoding: encoding,
    );
  }

  /// Serializes this header into canonical 44-byte RIFF/WAVE bytes.
  Uint8List toBytes() {
    if (dataLengthBytes < 0) {
      throw ArgumentError.value(
        dataLengthBytes,
        'dataLengthBytes',
        'Must be >= 0.',
      );
    }
    if (channels < wavMinChannels || channels > wavMaxChannels) {
      throw ArgumentError.value(
        channels,
        'channels',
        'Must be within WAV range [$wavMinChannels, $wavMaxChannels].',
      );
    }
    if (sampleRateHz <= 0) {
      throw ArgumentError.value(sampleRateHz, 'sampleRateHz', 'Must be > 0.');
    }
    if (bitsPerSample < wavMinBitsPerSample ||
        bitsPerSample > wavMaxBitsPerSample) {
      throw ArgumentError.value(
        bitsPerSample,
        'bitsPerSample',
        'Must be within WAV range '
            '[$wavMinBitsPerSample, $wavMaxBitsPerSample].',
      );
    }

    final riffChunkSize = 36 + dataLengthBytes;
    final formatCode = encoding == PcmEncoding.float ? 3 : 1;

    final header = Uint8List(44);
    final data = ByteData.sublistView(header);

    void writeAscii(int offset, String value) {
      for (var i = 0; i < value.length; i++) {
        header[offset + i] = value.codeUnitAt(i);
      }
    }

    writeAscii(0, 'RIFF');
    data.setUint32(4, riffChunkSize, Endian.little);
    writeAscii(8, 'WAVE');
    writeAscii(12, 'fmt ');
    data.setUint32(16, 16, Endian.little);
    data.setUint16(20, formatCode, Endian.little);
    data.setUint16(22, channels, Endian.little);
    data.setUint32(24, sampleRateHz, Endian.little);
    data.setUint32(28, byteRate, Endian.little);
    data.setUint16(32, blockAlign, Endian.little);
    data.setUint16(34, bitsPerSample, Endian.little);
    writeAscii(36, 'data');
    data.setUint32(40, dataLengthBytes, Endian.little);

    return header;
  }

  @override
  String toString() =>
      'WavHeader(sampleRateHz: $sampleRateHz, bitsPerSample: $bitsPerSample, channels: $channels, dataLengthBytes: $dataLengthBytes, encoding: $encoding)';

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is WavHeader &&
          runtimeType == other.runtimeType &&
          sampleRateHz == other.sampleRateHz &&
          bitsPerSample == other.bitsPerSample &&
          channels == other.channels &&
          dataLengthBytes == other.dataLengthBytes &&
          encoding == other.encoding;

  @override
  int get hashCode =>
      sampleRateHz.hashCode ^
      bitsPerSample.hashCode ^
      channels.hashCode ^
      dataLengthBytes.hashCode ^
      encoding.hashCode;
}
