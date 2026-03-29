import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:tts_flow_dart/tts_flow_dart.dart';

void main() {
  group('WavHeader', () {
    test('parse rejects unsupported format code', () {
      final bytes = WavHeader(
        sampleRateHz: 16000,
        bitsPerSample: 16,
        channels: 1,
        dataLengthBytes: 160,
      ).toBytes();

      final data = ByteData.sublistView(bytes);
      data.setUint16(20, 6, Endian.little);

      expect(() => WavHeader.parse(bytes), throwsFormatException);
    });

    test('fromPcmDescriptor preserves encoding', () {
      const descriptor = PcmDescriptor(
        sampleRateHz: 48000,
        bitsPerSample: 32,
        channels: 2,
        encoding: PcmEncoding.float,
      );
      final header = WavHeader.fromPcmDescriptor(
        descriptor,
        dataLengthBytes: 3200,
      );

      expect(header.toPcmDescriptor(), descriptor);
      expect(header.blockAlign, 8);
      expect(header.byteRate, 384000);
    });

    group('toBytes', () {
      test('produces exactly 44 bytes', () {
        final bytes = WavHeader(
          sampleRateHz: 24000,
          bitsPerSample: 16,
          channels: 1,
          dataLengthBytes: 0,
        ).toBytes();
        expect(bytes.length, 44);
      });

      test('writes RIFF/WAVE magic bytes', () {
        final bytes = WavHeader(
          sampleRateHz: 24000,
          bitsPerSample: 16,
          channels: 1,
          dataLengthBytes: 0,
        ).toBytes();
        expect(String.fromCharCodes(bytes.sublist(0, 4)), 'RIFF');
        expect(String.fromCharCodes(bytes.sublist(8, 12)), 'WAVE');
      });

      test('writes fmt and data sub-chunk markers', () {
        final bytes = WavHeader(
          sampleRateHz: 24000,
          bitsPerSample: 16,
          channels: 1,
          dataLengthBytes: 0,
        ).toBytes();
        expect(String.fromCharCodes(bytes.sublist(12, 16)), 'fmt ');
        expect(String.fromCharCodes(bytes.sublist(36, 40)), 'data');
      });

      test('writes fmt chunk size 16 at offset 16', () {
        final bytes = WavHeader(
          sampleRateHz: 24000,
          bitsPerSample: 16,
          channels: 1,
          dataLengthBytes: 0,
        ).toBytes();
        final data = ByteData.sublistView(bytes);
        expect(data.getUint32(16, Endian.little), 16);
      });

      test('PCM signedInt uses format code 1', () {
        final bytes = WavHeader(
          sampleRateHz: 16000,
          bitsPerSample: 16,
          channels: 1,
          dataLengthBytes: 0,
        ).toBytes();
        final data = ByteData.sublistView(bytes);
        expect(data.getUint16(20, Endian.little), 1);
      });

      test('PCM float uses format code 3', () {
        final bytes = WavHeader(
          sampleRateHz: 16000,
          bitsPerSample: 32,
          channels: 1,
          encoding: PcmEncoding.float,
          dataLengthBytes: 0,
        ).toBytes();
        final data = ByteData.sublistView(bytes);
        expect(data.getUint16(20, Endian.little), 3);
      });

      test('embeds channels, sampleRate, bitsPerSample correctly', () {
        const sampleRateHz = 44100;
        const bitsPerSample = 24;
        const channels = 2;
        final bytes = WavHeader(
          sampleRateHz: sampleRateHz,
          bitsPerSample: bitsPerSample,
          channels: channels,
          dataLengthBytes: 0,
        ).toBytes();
        final data = ByteData.sublistView(bytes);
        expect(data.getUint16(22, Endian.little), channels);
        expect(data.getUint32(24, Endian.little), sampleRateHz);
        expect(data.getUint16(34, Endian.little), bitsPerSample);
      });

      test('computes blockAlign and byteRate correctly', () {
        // 2 channels × 16 bits = 4 bytes/frame; byteRate = 44100 × 4 = 176400
        final header = WavHeader(
          sampleRateHz: 44100,
          bitsPerSample: 16,
          channels: 2,
          dataLengthBytes: 0,
        );
        final bytes = header.toBytes();
        final data = ByteData.sublistView(bytes);
        expect(data.getUint16(32, Endian.little), header.blockAlign);
        expect(data.getUint32(28, Endian.little), header.byteRate);
      });

      test('writes RIFF chunk size as 36 + dataLengthBytes', () {
        const dataLen = 8000;
        final bytes = WavHeader(
          sampleRateHz: 24000,
          bitsPerSample: 16,
          channels: 1,
          dataLengthBytes: dataLen,
        ).toBytes();
        final data = ByteData.sublistView(bytes);
        expect(data.getUint32(4, Endian.little), 36 + dataLen);
        expect(data.getUint32(40, Endian.little), dataLen);
      });

      test('round-trips through parse for signed-int PCM', () {
        final original = WavHeader(
          sampleRateHz: 22050,
          bitsPerSample: 16,
          channels: 1,
          dataLengthBytes: 4410,
        );
        expect(WavHeader.parse(original.toBytes()), original);
      });

      test('round-trips through parse for IEEE float PCM', () {
        final original = WavHeader(
          sampleRateHz: 48000,
          bitsPerSample: 32,
          channels: 2,
          encoding: PcmEncoding.float,
          dataLengthBytes: 9600,
        );
        expect(WavHeader.parse(original.toBytes()), original);
      });

      test('fromPcmDescriptor produces same bytes as manual constructor', () {
        const descriptor = PcmDescriptor(
          sampleRateHz: 24000,
          bitsPerSample: 16,
          channels: 1,
          encoding: PcmEncoding.signedInt,
        );
        const dataLengthBytes = 4800;
        final fromDescriptor = WavHeader.fromPcmDescriptor(
          descriptor,
          dataLengthBytes: dataLengthBytes,
        ).toBytes();
        final fromConstructor = WavHeader(
          sampleRateHz: descriptor.sampleRateHz,
          bitsPerSample: descriptor.bitsPerSample,
          channels: descriptor.channels,
          encoding: descriptor.encoding,
          dataLengthBytes: dataLengthBytes,
        ).toBytes();
        expect(fromDescriptor, fromConstructor);
      });
    });
  });
}
