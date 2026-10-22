import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:tts_flow_dart/tts_flow_dart.dart';

/// A sanitized, captured Provider stream that can be replayed offline.
///
/// The manifest and chunks live under `assets/fixtures/`; their schema is
/// documented in `docs/provider_playback_fixtures.md`. Arrival offsets are
/// measured from the first audio chunk, with derived gaps stored in the manifest.
final class ProviderPlaybackFixture {
  ProviderPlaybackFixture._({
    required this.provider,
    required this.kind,
    required this.sampleRateHz,
    required this.channels,
    required this.audioSpec,
    required List<ProviderPlaybackFixtureChunk> chunks,
  }) : chunks = List.unmodifiable(chunks);

  final String provider;
  final String kind;

  /// Capture metadata retained for every encoded and PCM fixture.
  final int sampleRateHz;
  final int channels;
  final TtsAudioSpec audioSpec;
  final List<ProviderPlaybackFixtureChunk> chunks;

  /// 将同一条编码流切成不对齐帧/页的网络块，不重编码或复制容器头。
  ProviderPlaybackFixture fragmented({Duration supplyGap = Duration.zero}) {
    final bytes = Uint8List.fromList(
      chunks.expand((chunk) => chunk.bytes).toList(),
    );
    // 首部按字节拆开，后续固定切片还会跨越 ADTS 帧和 Ogg 页。
    final cuts = <int>[
      0,
      ...[1, 2, 5, 13, 26, 27, 28, 31].where((cut) => cut < bytes.length),
    ];
    for (var offset = 389; offset < bytes.length; offset += 389) {
      cuts.add(offset);
    }
    cuts.add(bytes.length);
    final fragments = <ProviderPlaybackFixtureChunk>[];
    for (var i = 0; i < cuts.length - 1; i++) {
      fragments.add(
        ProviderPlaybackFixtureChunk(
          bytes: Uint8List.sublistView(bytes, cuts[i], cuts[i + 1]),
          arrivalOffset:
              Duration(milliseconds: i * 10) +
              (cuts[i] >= bytes.length ~/ 2 ? supplyGap : Duration.zero),
        ),
      );
    }
    return ProviderPlaybackFixture._(
      provider: provider,
      kind: 'fragmented',
      sampleRateHz: sampleRateHz,
      channels: channels,
      audioSpec: audioSpec,
      chunks: fragments,
    );
  }

  /// Loads [manifestAsset] and its neighboring raw audio chunk assets.
  static Future<ProviderPlaybackFixture> load({
    required String manifestAsset,
    AssetBundle? bundle,
  }) async {
    final assetBundle = bundle ?? rootBundle;
    final manifest = _asMap(
      jsonDecode(await assetBundle.loadString(manifestAsset)),
      manifestAsset,
    );
    final format = _requiredString(manifest, 'format', manifestAsset);
    final directory = manifestAsset.substring(
      0,
      manifestAsset.lastIndexOf('/') + 1,
    );
    final entries = _asList(manifest['chunks'], '$manifestAsset.chunks');
    if (entries.isEmpty) {
      throw FormatException('$manifestAsset must include at least one chunk.');
    }
    final sampleRateHz = _requiredPositiveInt(
      manifest,
      'sampleRateHz',
      manifestAsset,
    );
    final channels = _requiredPositiveInt(manifest, 'channels', manifestAsset);

    var previousOffset = -1;
    final chunks = <ProviderPlaybackFixtureChunk>[];
    for (var index = 0; index < entries.length; index += 1) {
      final entry = _asMap(entries[index], '$manifestAsset.chunks[$index]');
      final file = _requiredString(
        entry,
        'file',
        '$manifestAsset.chunks[$index]',
      );
      if (file.contains('/') ||
          file.contains('\\') ||
          file == '.' ||
          file == '..') {
        throw FormatException(
          '$manifestAsset.chunks[$index].file must name a neighboring asset.',
        );
      }
      final offset = _requiredInt(
        entry,
        'arrivalOffsetMs',
        '$manifestAsset.chunks[$index]',
      );
      if (offset < 0 ||
          offset < previousOffset ||
          (index == 0 && offset != 0)) {
        throw FormatException(
          '$manifestAsset chunk offsets must start at 0 and be non-decreasing.',
        );
      }
      previousOffset = offset;
      final asset = await assetBundle.load('$directory$file');
      chunks.add(
        ProviderPlaybackFixtureChunk(
          bytes: Uint8List.fromList(
            asset.buffer.asUint8List(asset.offsetInBytes, asset.lengthInBytes),
          ),
          arrivalOffset: Duration(milliseconds: offset),
        ),
      );
    }

    return ProviderPlaybackFixture._(
      provider: _requiredString(manifest, 'provider', manifestAsset),
      kind: _requiredString(manifest, 'kind', manifestAsset),
      sampleRateHz: sampleRateHz,
      channels: channels,
      audioSpec: _audioSpecFromManifest(manifest, manifestAsset, format),
      chunks: chunks,
    );
  }
}

final class ProviderPlaybackFixtureChunk {
  const ProviderPlaybackFixtureChunk({
    required this.bytes,
    required this.arrivalOffset,
  });

  final Uint8List bytes;
  final Duration arrivalOffset;
}

/// A deterministic offline engine for a [ProviderPlaybackFixture].
final class ProviderPlaybackFixtureEngine
    with TtsEngineDefaults
    implements TtsEngine {
  ProviderPlaybackFixtureEngine(this.fixture);

  final ProviderPlaybackFixture fixture;

  @override
  String get engineId => 'fixture-${fixture.provider}-${fixture.kind}';

  @override
  int get maxInputCharacterCount => 0;

  @override
  bool get supportsStreaming => true;

  @override
  Set<AudioCapability> get outAudioCapabilities {
    final spec = fixture.audioSpec;
    switch (spec.format) {
      case TtsAudioFormat.pcm:
        final descriptor = spec.requirePcm;
        return {
          PcmCapability(
            sampleRatesHz: {descriptor.sampleRateHz},
            bitsPerSample: {descriptor.bitsPerSample},
            channels: {descriptor.channels},
            encodings: {descriptor.encoding},
          ),
        };
      case TtsAudioFormat.mp3:
        return const {Mp3Capability()};
      case TtsAudioFormat.opus:
        return const {OpusCapability()};
      case TtsAudioFormat.aac:
        return const {AacCapability()};
    }
  }

  @override
  Future<List<TtsVoice>> getAvailableVoices({String? locale}) async {
    return const [TtsVoice(voiceId: 'fixture', isDefault: true)];
  }

  @override
  Future<TtsVoice> getDefaultVoice() async {
    return const TtsVoice(voiceId: 'fixture', isDefault: true);
  }

  @override
  Future<TtsVoice> getDefaultVoiceForLocale(String locale) => getDefaultVoice();

  @override
  Future<void> init() async {}

  @override
  Stream<TtsChunk> synthesize(
    TtsRequest request,
    SynthesisControl control,
    TtsAudioSpec resolvedFormat,
  ) async* {
    if (resolvedFormat != fixture.audioSpec) {
      throw StateError('The fixture engine received an unexpected audio spec.');
    }
    final stopwatch = Stopwatch()..start();
    for (var index = 0; index < fixture.chunks.length; index += 1) {
      final chunk = fixture.chunks[index];
      final remaining = chunk.arrivalOffset - stopwatch.elapsed;
      if (remaining.inMicroseconds > 0) {
        await Future<void>.delayed(remaining);
      }
      if (control.isCanceled) {
        return;
      }
      yield TtsAudioChunk(
        requestKey: request.requestKey,
        sequenceNumber: index,
        bytes: Uint8List.fromList(chunk.bytes),
        audioSpec: fixture.audioSpec,
        isLastChunk: index == fixture.chunks.length - 1,
        timestamp: DateTime.now().toUtc(),
      );
    }
  }

  @override
  Future<void> dispose() async {}
}

TtsAudioSpec _audioSpecFromManifest(
  Map<String, Object?> manifest,
  String source,
  String format,
) {
  switch (format) {
    case 'mp3':
      return const TtsAudioSpec.mp3();
    case 'opus':
      return const TtsAudioSpec.opus();
    case 'aac':
      return const TtsAudioSpec.aac();
    case 'pcm':
      return TtsAudioSpec.pcm(
        PcmDescriptor(
          sampleRateHz: _requiredInt(manifest, 'sampleRateHz', source),
          bitsPerSample: _requiredInt(manifest, 'bitsPerSample', source),
          channels: _requiredInt(manifest, 'channels', source),
          encoding: _pcmEncoding(
            _requiredString(manifest, 'encoding', source),
            source,
          ),
        ),
      );
    default:
      throw FormatException('$source has unsupported format "$format".');
  }
}

PcmEncoding _pcmEncoding(String value, String source) {
  for (final encoding in PcmEncoding.values) {
    if (encoding.name == value) {
      return encoding;
    }
  }
  throw FormatException('$source has unsupported PCM encoding "$value".');
}

Map<String, Object?> _asMap(Object? value, String source) {
  if (value is! Map) {
    throw FormatException('$source must be a JSON object.');
  }
  return value.map((key, entry) => MapEntry('$key', entry));
}

List<Object?> _asList(Object? value, String source) {
  if (value is! List) {
    throw FormatException('$source must be a JSON array.');
  }
  return List<Object?>.from(value);
}

String _requiredString(Map<String, Object?> map, String key, String source) {
  final value = map[key];
  if (value is String && value.isNotEmpty) {
    return value;
  }
  throw FormatException('$source.$key must be a non-empty string.');
}

int _requiredInt(Map<String, Object?> map, String key, String source) {
  final value = map[key];
  if (value is int) {
    return value;
  }
  throw FormatException('$source.$key must be an integer.');
}

int _requiredPositiveInt(Map<String, Object?> map, String key, String source) {
  final value = _requiredInt(map, key, source);
  if (value > 0) {
    return value;
  }
  throw FormatException('$source.$key must be greater than zero.');
}
