import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tts_flow_dart/tts_flow_dart.dart';

import '../integration_test/support/provider_playback_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('captured MiMo assets preserve PCM bytes and derived jitter', () async {
    final continuous = await ProviderPlaybackFixture.load(
      manifestAsset: 'assets/fixtures/mimo/continuous/manifest.json',
    );
    final jitter = await ProviderPlaybackFixture.load(
      manifestAsset: 'assets/fixtures/mimo/jitter/manifest.json',
    );
    expect(
      continuous.audioSpec,
      TtsAudioSpec.pcm(const PcmDescriptor.s16Mono24KHz()),
    );
    expect(continuous.chunks.length, greaterThan(1));
    expect(jitter.chunks.length, continuous.chunks.length);
    for (var i = 0; i < continuous.chunks.length; i++) {
      expect(jitter.chunks[i].bytes, continuous.chunks[i].bytes);
      expect(
        jitter.chunks[i].arrivalOffset,
        continuous.chunks[i].arrivalOffset +
            Duration(milliseconds: i == 0 ? 0 : 850),
      );
    }
    await expectLater(
      ProviderPlaybackFixture.load(
        manifestAsset: 'assets/fixtures/mimo/invalid/manifest.json',
      ),
      throwsFormatException,
    );
  });

  test('loads a fixture and replays captured arrival offsets', () async {
    final fixture = await ProviderPlaybackFixture.load(
      manifestAsset: 'assets/fixtures/test/continuous/manifest.json',
      bundle: _MapAssetBundle({
        'assets/fixtures/test/continuous/manifest.json': utf8.encode('''
          {
            "provider": "test",
            "format": "pcm",
            "sampleRateHz": 24000,
            "bitsPerSample": 16,
            "channels": 1,
            "encoding": "signedInt",
            "kind": "continuous",
            "chunks": [
              {"file": "000.bin", "arrivalOffsetMs": 0},
              {"file": "001.bin", "arrivalOffsetMs": 2}
            ]
          }
        '''),
        'assets/fixtures/test/continuous/000.bin': [1, 2],
        'assets/fixtures/test/continuous/001.bin': [3, 4],
      }),
    );

    expect(fixture.provider, 'test');
    expect(fixture.kind, 'continuous');
    expect(fixture.sampleRateHz, 24000);
    expect(fixture.channels, 1);
    expect(
      fixture.audioSpec,
      TtsAudioSpec.pcm(const PcmDescriptor.s16Mono24KHz()),
    );
    expect(fixture.chunks.map((chunk) => chunk.bytes), [
      [1, 2],
      [3, 4],
    ]);
    expect(fixture.chunks.last.arrivalOffset, const Duration(milliseconds: 2));

    final engine = ProviderPlaybackFixtureEngine(fixture);
    final request = TtsRequest(requestKey: 'fixture-test', text: 'ignored');
    final chunks = await engine
        .synthesize(request, SynthesisControl(), fixture.audioSpec)
        .cast<TtsAudioChunk>()
        .toList();
    expect(chunks.map((chunk) => chunk.sequenceNumber), [0, 1]);
    expect(chunks.map((chunk) => chunk.isLastChunk), [false, true]);
    expect(chunks.expand((chunk) => chunk.bytes), [1, 2, 3, 4]);
  });

  test('rejects a fixture whose offsets do not start at zero', () async {
    await expectLater(
      ProviderPlaybackFixture.load(
        manifestAsset: 'assets/fixtures/test/invalid/manifest.json',
        bundle: _MapAssetBundle({
          'assets/fixtures/test/invalid/manifest.json': utf8.encode('''
            {
              "provider": "test", "format": "mp3", "sampleRateHz": 24000,
              "channels": 1, "kind": "invalid",
              "chunks": [{"file": "000.bin", "arrivalOffsetMs": 1}]
            }
          '''),
          'assets/fixtures/test/invalid/000.bin': [0],
        }),
      ),
      throwsFormatException,
    );
  });

  test('requires capture metadata for encoded fixtures', () async {
    await expectLater(
      ProviderPlaybackFixture.load(
        manifestAsset: 'assets/fixtures/test/invalid/metadata.json',
        bundle: _MapAssetBundle({
          'assets/fixtures/test/invalid/metadata.json': utf8.encode('''
            {
              "provider": "test", "format": "mp3", "kind": "invalid",
              "chunks": [{"file": "000.bin", "arrivalOffsetMs": 0}]
            }
          '''),
          'assets/fixtures/test/invalid/000.bin': [0],
        }),
      ),
      throwsFormatException,
    );
  });
}

final class _MapAssetBundle extends CachingAssetBundle {
  _MapAssetBundle(Map<String, List<int>> assets)
    : _assets = assets.map(
        (key, value) => MapEntry(key, Uint8List.fromList(value)),
      );

  final Map<String, Uint8List> _assets;

  @override
  Future<ByteData> load(String key) async {
    final bytes = _assets[key];
    if (bytes == null) {
      throw StateError('Asset not found: $key');
    }
    return ByteData.sublistView(bytes);
  }
}
