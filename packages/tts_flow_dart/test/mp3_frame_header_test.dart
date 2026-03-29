import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:tts_flow_dart/tts_flow_dart.dart';

void main() {
  group('Mp3FrameHeader', () {
    test('parses a valid MPEG1 Layer3 frame', () {
      final frame = _buildMpeg1Layer3Frame(
        bitrateIndex: 9, // 128 kbps
        sampleRateIndex: 0, // 44100 Hz
        channelModeBits: 1, // joint stereo
      );

      final header = Mp3FrameHeader.parse(frame);

      expect(header.version, Mp3MpegVersion.mpeg1);
      expect(header.layer, Mp3Layer.layer3);
      expect(header.bitrateKbps, 128);
      expect(header.sampleRateHz, 44100);
      expect(header.channelMode, Mp3ChannelMode.jointStereo);
      expect(header.channelCount, 2);
      expect(header.frameLengthBytes, frame.length);
      expect(header.samplesPerFrame, 1152);
      expect(header.hasCrc, isFalse);
      expect(header.isPadded, isFalse);
    });

    test('parse skips ID3v2 tag with footer flag', () {
      final frame = _buildMpeg1Layer3Frame(
        bitrateIndex: 9,
        sampleRateIndex: 0,
        channelModeBits: 3, // mono
      );
      final id3WithFooter = Uint8List.fromList([
        // ID3 header (10 bytes)
        0x49, 0x44, 0x33, 0x04, 0x00, 0x10, 0x00, 0x00, 0x00, 0x00,
        // Footer (10 bytes)
        ...List<int>.filled(10, 0),
        ...frame,
      ]);

      final header = Mp3FrameHeader.parse(id3WithFooter);
      expect(header.channelMode, Mp3ChannelMode.mono);
      expect(header.channelCount, 1);
    });

    test('tryParse returns null for short or invalid data', () {
      expect(
        Mp3FrameHeader.tryParse(Uint8List.fromList([0xFF, 0xFB, 0x90])),
        isNull,
      );
      expect(
        Mp3FrameHeader.tryParse(Uint8List.fromList([0x00, 0x11, 0x22, 0x33])),
        isNull,
      );
    });

    test('audioStartOffset returns null for truncated ID3 header', () {
      final truncatedId3 = Uint8List.fromList([0x49, 0x44, 0x33, 0x04, 0x00]);
      expect(Mp3FrameHeader.audioStartOffset(truncatedId3), isNull);
    });

    test('isCompatibleWith compares channel count, not exact mode', () {
      final base = Mp3FrameHeader.parse(
        _buildMpeg1Layer3Frame(
          bitrateIndex: 9,
          sampleRateIndex: 0,
          channelModeBits: 0, // stereo
        ),
      );
      final jointStereo = Mp3FrameHeader.parse(
        _buildMpeg1Layer3Frame(
          bitrateIndex: 10,
          sampleRateIndex: 0,
          channelModeBits: 1, // joint stereo
        ),
      );
      final mono = Mp3FrameHeader.parse(
        _buildMpeg1Layer3Frame(
          bitrateIndex: 9,
          sampleRateIndex: 0,
          channelModeBits: 3, // mono
        ),
      );

      expect(base.isCompatibleWith(jointStereo), isTrue);
      expect(base.isCompatibleWith(mono), isFalse);
    });
  });
}

Uint8List _buildMpeg1Layer3Frame({
  required int bitrateIndex,
  required int sampleRateIndex,
  required int channelModeBits,
}) {
  final rawHeader =
      (0x7FF << 21) | // sync
      (0x3 << 19) | // MPEG1
      (0x1 << 17) | // Layer III
      (0x1 << 16) | // no CRC
      ((bitrateIndex & 0xF) << 12) |
      ((sampleRateIndex & 0x3) << 10) |
      (0 << 9) | // no padding
      ((channelModeBits & 0x3) << 6);

  final headerBytes = Uint8List.fromList([
    (rawHeader >> 24) & 0xFF,
    (rawHeader >> 16) & 0xFF,
    (rawHeader >> 8) & 0xFF,
    rawHeader & 0xFF,
  ]);

  final bitrateKbps = switch (bitrateIndex) {
    1 => 32,
    2 => 40,
    3 => 48,
    4 => 56,
    5 => 64,
    6 => 80,
    7 => 96,
    8 => 112,
    9 => 128,
    10 => 160,
    11 => 192,
    12 => 224,
    13 => 256,
    14 => 320,
    _ => throw ArgumentError.value(bitrateIndex, 'bitrateIndex'),
  };

  final sampleRateHz = switch (sampleRateIndex) {
    0 => 44100,
    1 => 48000,
    2 => 32000,
    _ => throw ArgumentError.value(sampleRateIndex, 'sampleRateIndex'),
  };

  final frameLength = ((144 * bitrateKbps * 1000) / sampleRateHz).floor();
  return Uint8List.fromList([
    ...headerBytes,
    ...List<int>.filled(frameLength - 4, 0),
  ]);
}
