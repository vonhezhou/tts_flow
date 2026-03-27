import 'package:tts_flow_dart/src/base/pcm_descriptor.dart';
import 'package:tts_flow_dart/src/core/audio_spec.dart';

/// Capability declaration used during format/spec negotiation.
sealed class AudioCapability {
  const AudioCapability({required this.format});

  final TtsAudioFormat format;

  bool supports(TtsAudioSpec spec) {
    if (spec.format != format) {
      return false;
    }
    return true;
  }
}

/// Capability for non-PCM formats where only the format value is needed.
final class SimpleFormatCapability extends AudioCapability {
  const SimpleFormatCapability({required super.format});
}

/// Capability for PCM format that constrains descriptor fields.
final class PcmCapability extends AudioCapability {
  PcmCapability({
    Set<int>? sampleRatesHz,
    Set<int>? bitsPerSample,
    Set<int>? channels,
    Set<PcmEncoding>? encodings,
  })  : sampleRatesHz = sampleRatesHz == null
            ? null
            : Set.unmodifiable(sampleRatesHz),
        bitsPerSample = bitsPerSample == null
            ? null
            : Set.unmodifiable(bitsPerSample),
        channels = channels == null ? null : Set.unmodifiable(channels),
        encodings = encodings == null ? null : Set.unmodifiable(encodings),
        super(format: TtsAudioFormat.pcm) {
    for (final sampleRate in this.sampleRatesHz ?? const <int>{}) {
      if (sampleRate < wavMinSampleRateHz || sampleRate > wavMaxSampleRateHz) {
        throw ArgumentError.value(
          sampleRate,
          'sampleRatesHz',
          'Each value must be within WAV range '
              '[$wavMinSampleRateHz, $wavMaxSampleRateHz].',
        );
      }
    }
    for (final bitDepth in this.bitsPerSample ?? const <int>{}) {
      if (bitDepth < wavMinBitsPerSample || bitDepth > wavMaxBitsPerSample) {
        throw ArgumentError.value(
          bitDepth,
          'bitsPerSample',
          'Each value must be within WAV range '
              '[$wavMinBitsPerSample, $wavMaxBitsPerSample].',
        );
      }
    }
    for (final channelCount in this.channels ?? const <int>{}) {
      if (channelCount < wavMinChannels || channelCount > wavMaxChannels) {
        throw ArgumentError.value(
          channelCount,
          'channels',
          'Each value must be within WAV range '
              '[$wavMinChannels, $wavMaxChannels].',
        );
      }
    }
  }

  PcmCapability.wav()
      : this(
          encodings: Set.from(PcmEncoding.values),
        );

  final Set<int>? sampleRatesHz;
  final Set<int>? bitsPerSample;
  final Set<int>? channels;
  final Set<PcmEncoding>? encodings;

  bool supportsSampleRateHz(int sampleRateHz) {
    if (sampleRateHz < wavMinSampleRateHz ||
        sampleRateHz > wavMaxSampleRateHz) {
      return false;
    }
    final values = sampleRatesHz;
    if (values == null) {
      return true;
    }
    if (values.isEmpty) {
      return false;
    }
    return values.contains(sampleRateHz);
  }

  bool supportsBitsPerSample(int bitsPerSample) {
    if (bitsPerSample < wavMinBitsPerSample ||
        bitsPerSample > wavMaxBitsPerSample) {
      return false;
    }
    final values = this.bitsPerSample;
    if (values == null) {
      return true;
    }
    if (values.isEmpty) {
      return false;
    }
    return values.contains(bitsPerSample);
  }

  bool supportsChannelCount(int channels) {
    if (channels < wavMinChannels || channels > wavMaxChannels) {
      return false;
    }
    final values = this.channels;
    if (values == null) {
      return true;
    }
    if (values.isEmpty) {
      return false;
    }
    return values.contains(channels);
  }

  bool supportsEncoding(PcmEncoding encoding) {
    final values = encodings;
    if (values == null) {
      return true;
    }
    if (values.isEmpty) {
      return false;
    }
    return values.contains(encoding);
  }

  @override
  bool supports(TtsAudioSpec spec) {
    if (!super.supports(spec)) {
      return false;
    }
    final pcm = spec.pcm;
    if (pcm == null) {
      return false;
    }
    return supportsSampleRateHz(pcm.sampleRateHz) &&
        supportsBitsPerSample(pcm.bitsPerSample) &&
        supportsChannelCount(pcm.channels) &&
      supportsEncoding(pcm.encoding);
  }

  @override
  String toString() {
    return 'PcmCapability(sampleRatesHz: $sampleRatesHz, '
      'bitsPerSample: $bitsPerSample, '
      'channels: $channels, '
        'encodings: $encodings)';
  }

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        other is PcmCapability &&
            _sameNullableIntSet(sampleRatesHz, other.sampleRatesHz) &&
            _sameNullableIntSet(bitsPerSample, other.bitsPerSample) &&
            _sameNullableIntSet(channels, other.channels) &&
            _sameNullableEncodingSet(encodings, other.encodings);
  }

  @override
  int get hashCode => Object.hash(
        _hashNullableIntSet(sampleRatesHz),
        _hashNullableIntSet(bitsPerSample),
        _hashNullableIntSet(channels),
        _hashNullableEncodingSet(encodings),
      );
}

bool _sameNullableIntSet(Set<int>? a, Set<int>? b) {
  if (a == null || b == null) {
    return a == b;
  }
  if (a.length != b.length) {
    return false;
  }
  for (final value in a) {
    if (!b.contains(value)) {
      return false;
    }
  }
  return true;
}

bool _sameNullableEncodingSet(Set<PcmEncoding>? a, Set<PcmEncoding>? b) {
  if (a == null || b == null) {
    return a == b;
  }
  if (a.length != b.length) {
    return false;
  }
  for (final value in a) {
    if (!b.contains(value)) {
      return false;
    }
  }
  return true;
}

int? _hashNullableIntSet(Set<int>? values) {
  if (values == null) {
    return null;
  }
  return Object.hashAll(values.toList()..sort());
}

int? _hashNullableEncodingSet(Set<PcmEncoding>? values) {
  if (values == null) {
    return null;
  }
  return Object.hashAll(values.toList()..sort((a, b) => a.index - b.index));
}
