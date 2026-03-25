import 'dart:typed_data';

enum Mp3MpegVersion { mpeg1, mpeg2, mpeg25 }

enum Mp3Layer { layer1, layer2, layer3 }

enum Mp3ChannelMode { stereo, jointStereo, dualChannel, mono }

final class Mp3FrameHeader {
  const Mp3FrameHeader({
    required this.version,
    required this.layer,
    required this.bitrateKbps,
    required this.sampleRateHz,
    required this.channelMode,
    required this.hasCrc,
    required this.isPadded,
    required this.frameLengthBytes,
    required this.samplesPerFrame,
  })  : assert(bitrateKbps > 0),
        assert(sampleRateHz > 0),
        assert(frameLengthBytes >= 4),
        assert(samplesPerFrame > 0);

  final Mp3MpegVersion version;
  final Mp3Layer layer;
  final int bitrateKbps;
  final int sampleRateHz;
  final Mp3ChannelMode channelMode;
  final bool hasCrc;
  final bool isPadded;
  final int frameLengthBytes;
  final int samplesPerFrame;

  int get channelCount => channelMode == Mp3ChannelMode.mono ? 1 : 2;

  bool isCompatibleWith(Mp3FrameHeader other) {
    return version == other.version &&
        layer == other.layer &&
        sampleRateHz == other.sampleRateHz &&
        channelCount == other.channelCount;
  }

  static Mp3FrameHeader parse(Uint8List bytes) {
    final header = tryParse(bytes);
    if (header == null) {
      throw const FormatException(
        'Invalid MP3 data: no valid MPEG audio frame header found.',
      );
    }
    return header;
  }

  static Mp3FrameHeader? tryParse(Uint8List bytes) {
    if (bytes.length < 4) {
      return null;
    }

    final startOffset = _computeAudioStartOffset(bytes);
    if (startOffset == null || startOffset > bytes.length - 4) {
      return null;
    }

    for (var offset = startOffset; offset <= bytes.length - 4; offset++) {
      final header = _tryParseAt(bytes, offset);
      if (header != null) {
        return header;
      }
    }

    return null;
  }

  static int? _computeAudioStartOffset(Uint8List bytes) {
    if (bytes.length < 3) {
      return 0;
    }
    if (bytes[0] != 0x49 || bytes[1] != 0x44 || bytes[2] != 0x33) {
      return 0;
    }
    if (bytes.length < 10) {
      return null;
    }

    final flags = bytes[5];
    final tagSize = _decodeSynchsafeInt(bytes, 6);
    final footerLength = (flags & 0x10) != 0 ? 10 : 0;
    return 10 + tagSize + footerLength;
  }

  static int _decodeSynchsafeInt(Uint8List bytes, int offset) {
    return ((bytes[offset] & 0x7F) << 21) |
        ((bytes[offset + 1] & 0x7F) << 14) |
        ((bytes[offset + 2] & 0x7F) << 7) |
        (bytes[offset + 3] & 0x7F);
  }

  static Mp3FrameHeader? _tryParseAt(Uint8List bytes, int offset) {
    final data = ByteData.sublistView(bytes, offset, offset + 4);
    final rawHeader = data.getUint32(0, Endian.big);

    if ((rawHeader & 0xFFE00000) != 0xFFE00000) {
      return null;
    }

    final versionBits = (rawHeader >> 19) & 0x3;
    final layerBits = (rawHeader >> 17) & 0x3;
    final protectionBit = (rawHeader >> 16) & 0x1;
    final bitrateIndex = (rawHeader >> 12) & 0xF;
    final sampleRateIndex = (rawHeader >> 10) & 0x3;
    final paddingBit = (rawHeader >> 9) & 0x1;
    final channelModeBits = (rawHeader >> 6) & 0x3;

    final version = switch (versionBits) {
      0 => Mp3MpegVersion.mpeg25,
      2 => Mp3MpegVersion.mpeg2,
      3 => Mp3MpegVersion.mpeg1,
      _ => null,
    };
    if (version == null) {
      return null;
    }

    final layer = switch (layerBits) {
      1 => Mp3Layer.layer3,
      2 => Mp3Layer.layer2,
      3 => Mp3Layer.layer1,
      _ => null,
    };
    if (layer == null) {
      return null;
    }

    if (bitrateIndex == 0 || bitrateIndex == 0xF || sampleRateIndex == 0x3) {
      return null;
    }

    final bitrateKbps = _bitrateFor(
      version: version,
      layer: layer,
      bitrateIndex: bitrateIndex,
    );
    final sampleRateHz = _sampleRateFor(
      version: version,
      sampleRateIndex: sampleRateIndex,
    );
    if (bitrateKbps == null || sampleRateHz == null) {
      return null;
    }

    final channelMode = Mp3ChannelMode.values[channelModeBits];
    final samplesPerFrame = _samplesPerFrameFor(version: version, layer: layer);
    final frameLengthBytes = _frameLengthFor(
      version: version,
      layer: layer,
      bitrateKbps: bitrateKbps,
      sampleRateHz: sampleRateHz,
      isPadded: paddingBit == 1,
    );
    if (frameLengthBytes < 4) {
      return null;
    }

    return Mp3FrameHeader(
      version: version,
      layer: layer,
      bitrateKbps: bitrateKbps,
      sampleRateHz: sampleRateHz,
      channelMode: channelMode,
      hasCrc: protectionBit == 0,
      isPadded: paddingBit == 1,
      frameLengthBytes: frameLengthBytes,
      samplesPerFrame: samplesPerFrame,
    );
  }

  static int? _bitrateFor({
    required Mp3MpegVersion version,
    required Mp3Layer layer,
    required int bitrateIndex,
  }) {
    const mpeg1Layer1 = <int?>[
      null,
      32,
      64,
      96,
      128,
      160,
      192,
      224,
      256,
      288,
      320,
      352,
      384,
      416,
      448,
      null,
    ];
    const mpeg1Layer2 = <int?>[
      null,
      32,
      48,
      56,
      64,
      80,
      96,
      112,
      128,
      160,
      192,
      224,
      256,
      320,
      384,
      null,
    ];
    const mpeg1Layer3 = <int?>[
      null,
      32,
      40,
      48,
      56,
      64,
      80,
      96,
      112,
      128,
      160,
      192,
      224,
      256,
      320,
      null,
    ];
    const mpeg2Layer1 = <int?>[
      null,
      32,
      48,
      56,
      64,
      80,
      96,
      112,
      128,
      144,
      160,
      176,
      192,
      224,
      256,
      null,
    ];
    const mpeg2Layer23 = <int?>[
      null,
      8,
      16,
      24,
      32,
      40,
      48,
      56,
      64,
      80,
      96,
      112,
      128,
      144,
      160,
      null,
    ];

    final table = switch ((version, layer)) {
      (Mp3MpegVersion.mpeg1, Mp3Layer.layer1) => mpeg1Layer1,
      (Mp3MpegVersion.mpeg1, Mp3Layer.layer2) => mpeg1Layer2,
      (Mp3MpegVersion.mpeg1, Mp3Layer.layer3) => mpeg1Layer3,
      (_, Mp3Layer.layer1) => mpeg2Layer1,
      _ => mpeg2Layer23,
    };
    return table[bitrateIndex];
  }

  static int? _sampleRateFor({
    required Mp3MpegVersion version,
    required int sampleRateIndex,
  }) {
    const mpeg1Rates = <int?>[44100, 48000, 32000, null];
    const mpeg2Rates = <int?>[22050, 24000, 16000, null];
    const mpeg25Rates = <int?>[11025, 12000, 8000, null];

    final table = switch (version) {
      Mp3MpegVersion.mpeg1 => mpeg1Rates,
      Mp3MpegVersion.mpeg2 => mpeg2Rates,
      Mp3MpegVersion.mpeg25 => mpeg25Rates,
    };
    return table[sampleRateIndex];
  }

  static int _samplesPerFrameFor({
    required Mp3MpegVersion version,
    required Mp3Layer layer,
  }) {
    return switch ((version, layer)) {
      (_, Mp3Layer.layer1) => 384,
      (_, Mp3Layer.layer2) => 1152,
      (Mp3MpegVersion.mpeg1, Mp3Layer.layer3) => 1152,
      _ => 576,
    };
  }

  static int _frameLengthFor({
    required Mp3MpegVersion version,
    required Mp3Layer layer,
    required int bitrateKbps,
    required int sampleRateHz,
    required bool isPadded,
  }) {
    final padding = isPadded ? 1 : 0;
    return switch ((version, layer)) {
      (_, Mp3Layer.layer1) =>
        ((((12 * bitrateKbps * 1000) / sampleRateHz).floor()) + padding) * 4,
      (Mp3MpegVersion.mpeg1, Mp3Layer.layer3) =>
        (((144 * bitrateKbps * 1000) / sampleRateHz).floor()) + padding,
      (_, Mp3Layer.layer3) =>
        (((72 * bitrateKbps * 1000) / sampleRateHz).floor()) + padding,
      _ => (((144 * bitrateKbps * 1000) / sampleRateHz).floor()) + padding,
    };
  }

  @override
  String toString() {
    return 'Mp3FrameHeader(version: $version, layer: $layer, bitrateKbps: $bitrateKbps, sampleRateHz: $sampleRateHz, channelMode: $channelMode, hasCrc: $hasCrc, isPadded: $isPadded, frameLengthBytes: $frameLengthBytes, samplesPerFrame: $samplesPerFrame)';
  }

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        other is Mp3FrameHeader &&
            runtimeType == other.runtimeType &&
            version == other.version &&
            layer == other.layer &&
            bitrateKbps == other.bitrateKbps &&
            sampleRateHz == other.sampleRateHz &&
            channelMode == other.channelMode &&
            hasCrc == other.hasCrc &&
            isPadded == other.isPadded &&
            frameLengthBytes == other.frameLengthBytes &&
            samplesPerFrame == other.samplesPerFrame;
  }

  @override
  int get hashCode {
    return version.hashCode ^
        layer.hashCode ^
        bitrateKbps.hashCode ^
        sampleRateHz.hashCode ^
        channelMode.hashCode ^
        hasCrc.hashCode ^
        isPadded.hashCode ^
        frameLengthBytes.hashCode ^
        samplesPerFrame.hashCode;
  }
}
