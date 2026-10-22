import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tts_flow_dart/tts_flow_dart.dart';

import '../integration_test/support/provider_playback_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final provider in ['derived_aac', 'derived_opus']) {
    test(
      '$provider fragmentation preserves one complete encoded stream',
      () async {
        final source = await ProviderPlaybackFixture.load(
          manifestAsset: 'assets/fixtures/$provider/continuous/manifest.json',
        );
        final normal = source.fragmented();
        final delayed = source.fragmented(
          supplyGap: const Duration(milliseconds: 2500),
        );
        final originalBytes = source.chunks.expand((c) => c.bytes).toList();
        expect(normal.chunks.expand((c) => c.bytes), originalBytes);
        expect(delayed.chunks.expand((c) => c.bytes), originalBytes);
        expect(normal.chunks.take(3).map((c) => c.bytes.length), [1, 1, 3]);
        expect(normal.audioSpec, source.audioSpec);
        var cursor = 0;
        for (var i = 0; i < normal.chunks.length; i++) {
          expect(
            delayed.chunks[i].arrivalOffset,
            normal.chunks[i].arrivalOffset +
                Duration(
                  milliseconds: cursor >= originalBytes.length ~/ 2 ? 2500 : 0,
                ),
          );
          cursor += normal.chunks[i].bytes.length;
        }
        expect(source.chunks, hasLength(1));
      },
    );
  }

  for (final entry in {
    'mimo_mp3': TtsAudioFormat.mp3,
    'derived_aac': TtsAudioFormat.aac,
    'derived_opus': TtsAudioFormat.opus,
  }.entries) {
    test(
      '${entry.key} assets carry encoded audio with capture metadata',
      () async {
        final fixture = await ProviderPlaybackFixture.load(
          manifestAsset:
              'assets/fixtures/${entry.key}/continuous/manifest.json',
        );
        expect(fixture.audioSpec.format, entry.value);
        expect(fixture.channels, 1);
        expect(
          fixture.sampleRateHz,
          entry.value == TtsAudioFormat.opus ? 48000 : 24000,
        );
        final bytes = Uint8List.fromList(
          fixture.chunks.expand((c) => c.bytes).toList(),
        );
        switch (entry.value) {
          case TtsAudioFormat.mp3:
            final header = Mp3FrameHeader.parse(bytes);
            expect(header.sampleRateHz, fixture.sampleRateHz);
            expect(header.channelCount, fixture.channels);
          case TtsAudioFormat.aac:
            expect(bytes[0], 0xff);
            expect(bytes[1] & 0xf6, 0xf0); // ADTS 同步字与 layer。
          case TtsAudioFormat.opus:
            expect(ascii.decode(bytes.sublist(0, 4)), 'OggS');
            expect(
              latin1.decode(bytes.take(200).toList()),
              contains('OpusHead'),
            );
          case TtsAudioFormat.pcm:
            fail('Encoded fixture must not masquerade as PCM.');
        }
      },
    );
  }

  test('captured Gemini long asset is 30 to 60 seconds of PCM24K', () async {
    final fixture = await ProviderPlaybackFixture.load(
      manifestAsset: 'assets/fixtures/gemini/long_continuous/manifest.json',
    );
    expect(
      fixture.audioSpec,
      TtsAudioSpec.pcm(const PcmDescriptor.s16Mono24KHz()),
    );
    final byteCount = fixture.chunks.fold<int>(
      0,
      (sum, chunk) => sum + chunk.bytes.length,
    );
    expect(byteCount / (24000 * 2), inInclusiveRange(30, 60));
    expect(fixture.chunks.every((chunk) => chunk.bytes.length.isEven), isTrue);
  });

  for (final provider in ['mimo', 'gemini']) {
    test(
      'captured $provider assets preserve PCM bytes and derived jitter',
      () async {
        final continuous = await ProviderPlaybackFixture.load(
          manifestAsset: 'assets/fixtures/$provider/continuous/manifest.json',
        );
        final jitter = await ProviderPlaybackFixture.load(
          manifestAsset: 'assets/fixtures/$provider/jitter/manifest.json',
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
            manifestAsset: 'assets/fixtures/$provider/invalid/manifest.json',
          ),
          throwsFormatException,
        );
      },
    );
  }

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
