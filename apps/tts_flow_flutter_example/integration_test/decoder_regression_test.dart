import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:tts_flow_dart/tts_flow_dart.dart';
import 'package:tts_flow_flutter/tts_flow_flutter.dart';

import 'support/provider_playback_fixture.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  for (final sampleRate in [24000, 16000]) {
    test(
      'native Decoder converts complete MP3 to PCM at $sampleRate Hz',
      () async {
        final fixture = await ProviderPlaybackFixture.load(
          manifestAsset: 'assets/fixtures/edge_mp3/continuous/manifest.json',
        );
        final directory = await Directory.systemTemp.createTemp(
          'decoder-regression-',
        );
        final file = File('${directory.path}/decoded.wav');
        final decoder = Decoder(
          outputId: 'native-decoder-regression',
          output: WavFileOutput(file.path),
          pcmFormat: PcmDescriptor(
            sampleRateHz: sampleRate,
            bitsPerSample: 16,
            channels: 1,
          ),
        );
        try {
          await decoder.init();
          await decoder.startWrite(
            TtsOutputWriteContext(
              requestKey: 'decode-mp3',
              audioSpec: fixture.audioSpec,
              voice: null,
              options: null,
            ),
          );
          for (var i = 0; i < fixture.chunks.length; i++) {
            await decoder.writeChunk(
              TtsAudioChunk(
                requestKey: 'decode-mp3',
                sequenceNumber: i,
                bytes: fixture.chunks[i].bytes,
                audioSpec: fixture.audioSpec,
                isLastChunk: i == fixture.chunks.length - 1,
                timestamp: DateTime.now().toUtc(),
              ),
            );
          }
          await decoder.finishWrite();
          final bytes = await file.readAsBytes();
          final header = WavHeader.parse(Uint8List.sublistView(bytes, 0, 44));
          expect(header.sampleRateHz, sampleRate);
          expect(header.channels, 1);
          expect(header.bitsPerSample, 16);
          expect(header.dataLengthBytes, bytes.length - 44);
          expect(
            header.dataLengthBytes / header.byteRate,
            inInclusiveRange(7.5, 8),
          );
          final pcm = ByteData.sublistView(bytes, 44);
          var energy = 0.0;
          for (var i = 0; i < pcm.lengthInBytes; i += 2) {
            final value = pcm.getInt16(i, Endian.little);
            energy += value * value;
          }
          // 验证原生插件确实解码了非静音整句，而非返回头部或空 PCM。
          expect(energy / (pcm.lengthInBytes ~/ 2), greaterThan(100));
        } finally {
          await decoder.dispose();
          await directory.delete(recursive: true);
        }
      },
    );
  }
}
