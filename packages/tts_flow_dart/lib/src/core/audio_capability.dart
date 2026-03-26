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
    Set<int> sampleRatesHz = const <int>{},
    this.minSampleRateHz,
    this.maxSampleRateHz,
    Set<int> bitsPerSample = const <int>{},
    this.minBitsPerSample,
    this.maxBitsPerSample,
    Set<int> channels = const <int>{},
    this.minChannels,
    this.maxChannels,
    required Set<PcmEncoding> encodings,
  })  : sampleRatesHz = Set.unmodifiable(sampleRatesHz),
        bitsPerSample = Set.unmodifiable(bitsPerSample),
        channels = Set.unmodifiable(channels),
        encodings = Set.unmodifiable(encodings),
        super(format: TtsAudioFormat.pcm) {
    final minRate = minSampleRateHz;
    final maxRate = maxSampleRateHz;
    final minBits = minBitsPerSample;
    final maxBits = maxBitsPerSample;
    final minChannelCount = minChannels;
    final maxChannelCount = maxChannels;

    if (sampleRatesHz.isEmpty && (minRate == null || maxRate == null)) {
      throw ArgumentError.value(
        sampleRatesHz,
        'sampleRatesHz',
        'Provide discrete sampleRatesHz or a min/max sample-rate range.',
      );
    }
    if ((minRate == null) != (maxRate == null)) {
      throw ArgumentError(
        'Both minSampleRateHz and maxSampleRateHz must be provided together.',
      );
    }
    if (minRate != null &&
        (minRate < wavMinSampleRateHz || minRate > wavMaxSampleRateHz)) {
      throw ArgumentError.value(
        minRate,
        'minSampleRateHz',
        'Must be within WAV range [$wavMinSampleRateHz, $wavMaxSampleRateHz].',
      );
    }
    if (maxRate != null &&
        (maxRate < wavMinSampleRateHz || maxRate > wavMaxSampleRateHz)) {
      throw ArgumentError.value(
        maxRate,
        'maxSampleRateHz',
        'Must be within WAV range [$wavMinSampleRateHz, $wavMaxSampleRateHz].',
      );
    }
    if (minRate != null && maxRate != null && minRate > maxRate) {
      throw ArgumentError.value(
        '$minRate..$maxRate',
        'sampleRateRange',
        'minSampleRateHz must be less than or equal to maxSampleRateHz.',
      );
    }
    for (final sampleRate in sampleRatesHz) {
      if (sampleRate < wavMinSampleRateHz || sampleRate > wavMaxSampleRateHz) {
        throw ArgumentError.value(
          sampleRate,
          'sampleRatesHz',
          'Each value must be within WAV range '
              '[$wavMinSampleRateHz, $wavMaxSampleRateHz].',
        );
      }
    }
    if (bitsPerSample.isEmpty && (minBits == null || maxBits == null)) {
      throw ArgumentError.value(
        bitsPerSample,
        'bitsPerSample',
        'Provide discrete bitsPerSample or a min/max bit-depth range.',
      );
    }
    if ((minBits == null) != (maxBits == null)) {
      throw ArgumentError(
        'Both minBitsPerSample and maxBitsPerSample must be provided together.',
      );
    }
    if (minBits != null &&
        (minBits < wavMinBitsPerSample || minBits > wavMaxBitsPerSample)) {
      throw ArgumentError.value(
        minBits,
        'minBitsPerSample',
        'Must be within WAV range '
            '[$wavMinBitsPerSample, $wavMaxBitsPerSample].',
      );
    }
    if (maxBits != null &&
        (maxBits < wavMinBitsPerSample || maxBits > wavMaxBitsPerSample)) {
      throw ArgumentError.value(
        maxBits,
        'maxBitsPerSample',
        'Must be within WAV range '
            '[$wavMinBitsPerSample, $wavMaxBitsPerSample].',
      );
    }
    if (minBits != null && maxBits != null && minBits > maxBits) {
      throw ArgumentError.value(
        '$minBits..$maxBits',
        'bitsPerSampleRange',
        'minBitsPerSample must be less than or equal to maxBitsPerSample.',
      );
    }
    for (final bitDepth in bitsPerSample) {
      if (bitDepth < wavMinBitsPerSample || bitDepth > wavMaxBitsPerSample) {
        throw ArgumentError.value(
          bitDepth,
          'bitsPerSample',
          'Each value must be within WAV range '
              '[$wavMinBitsPerSample, $wavMaxBitsPerSample].',
        );
      }
    }
    if (bitsPerSample.isEmpty && minBits == null && maxBits == null) {
      throw ArgumentError.value(
        bitsPerSample,
        'bitsPerSample',
        'Provide discrete bitsPerSample or a min/max bit-depth range.',
      );
    }
    if (channels.isEmpty &&
        (minChannelCount == null || maxChannelCount == null)) {
      throw ArgumentError.value(
        channels,
        'channels',
        'Provide discrete channels or a min/max channel-count range.',
      );
    }
    if ((minChannelCount == null) != (maxChannelCount == null)) {
      throw ArgumentError(
        'Both minChannels and maxChannels must be provided together.',
      );
    }
    if (minChannelCount != null &&
        (minChannelCount < wavMinChannels ||
            minChannelCount > wavMaxChannels)) {
      throw ArgumentError.value(
        minChannelCount,
        'minChannels',
        'Must be within WAV range [$wavMinChannels, $wavMaxChannels].',
      );
    }
    if (maxChannelCount != null &&
        (maxChannelCount < wavMinChannels ||
            maxChannelCount > wavMaxChannels)) {
      throw ArgumentError.value(
        maxChannelCount,
        'maxChannels',
        'Must be within WAV range [$wavMinChannels, $wavMaxChannels].',
      );
    }
    if (minChannelCount != null &&
        maxChannelCount != null &&
        minChannelCount > maxChannelCount) {
      throw ArgumentError.value(
        '$minChannelCount..$maxChannelCount',
        'channelRange',
        'minChannels must be less than or equal to maxChannels.',
      );
    }
    for (final channelCount in channels) {
      if (channelCount < wavMinChannels || channelCount > wavMaxChannels) {
        throw ArgumentError.value(
          channelCount,
          'channels',
          'Each value must be within WAV range '
              '[$wavMinChannels, $wavMaxChannels].',
        );
      }
    }
    if (channels.isEmpty &&
        minChannelCount == null &&
        maxChannelCount == null) {
      throw ArgumentError.value(
        channels,
        'channels',
        'Provide discrete channels or a min/max channel-count range.',
      );
    }
    if (encodings.isEmpty) {
      throw ArgumentError.value(encodings, 'encodings', 'Must not be empty.');
    }
  }

  PcmCapability.wav()
      : this(
          sampleRatesHz: const <int>{},
          minSampleRateHz: wavMinSampleRateHz,
          maxSampleRateHz: wavMaxSampleRateHz,
          bitsPerSample: const <int>{},
          minBitsPerSample: wavMinBitsPerSample,
          maxBitsPerSample: wavMaxBitsPerSample,
          channels: const <int>{},
          minChannels: wavMinChannels,
          maxChannels: wavMaxChannels,
          encodings: Set.from(PcmEncoding.values),
        );

  final Set<int> sampleRatesHz;
  final int? minSampleRateHz;
  final int? maxSampleRateHz;
  final Set<int> bitsPerSample;
  final int? minBitsPerSample;
  final int? maxBitsPerSample;
  final Set<int> channels;
  final int? minChannels;
  final int? maxChannels;
  final Set<PcmEncoding> encodings;

  bool get hasDiscreteSampleRates => sampleRatesHz.isNotEmpty;
  bool get hasSampleRateRange =>
      minSampleRateHz != null && maxSampleRateHz != null;
  bool get hasDiscreteBitsPerSample => bitsPerSample.isNotEmpty;
  bool get hasBitsPerSampleRange =>
      minBitsPerSample != null && maxBitsPerSample != null;
  bool get hasDiscreteChannels => channels.isNotEmpty;
  bool get hasChannelRange => minChannels != null && maxChannels != null;

  bool supportsSampleRateHz(int sampleRateHz) {
    if (sampleRateHz < wavMinSampleRateHz ||
        sampleRateHz > wavMaxSampleRateHz) {
      return false;
    }
    if (hasDiscreteSampleRates && !sampleRatesHz.contains(sampleRateHz)) {
      return false;
    }
    if (hasSampleRateRange) {
      final min = minSampleRateHz!;
      final max = maxSampleRateHz!;
      if (sampleRateHz < min || sampleRateHz > max) {
        return false;
      }
    }
    return true;
  }

  bool supportsBitsPerSample(int bitsPerSample) {
    if (bitsPerSample < wavMinBitsPerSample ||
        bitsPerSample > wavMaxBitsPerSample) {
      return false;
    }
    if (hasDiscreteBitsPerSample &&
        !this.bitsPerSample.contains(bitsPerSample)) {
      return false;
    }
    if (hasBitsPerSampleRange) {
      final min = minBitsPerSample!;
      final max = maxBitsPerSample!;
      if (bitsPerSample < min || bitsPerSample > max) {
        return false;
      }
    }
    return true;
  }

  bool supportsChannelCount(int channels) {
    if (channels < wavMinChannels || channels > wavMaxChannels) {
      return false;
    }
    if (hasDiscreteChannels && !this.channels.contains(channels)) {
      return false;
    }
    if (hasChannelRange) {
      final min = minChannels!;
      final max = maxChannels!;
      if (channels < min || channels > max) {
        return false;
      }
    }
    return true;
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
        encodings.contains(pcm.encoding);
  }

  @override
  String toString() {
    return 'PcmCapability(sampleRatesHz: $sampleRatesHz, '
        'minSampleRateHz: $minSampleRateHz, '
        'maxSampleRateHz: $maxSampleRateHz, '
        'bitsPerSample: $bitsPerSample, channels: $channels, '
        'minBitsPerSample: $minBitsPerSample, '
        'maxBitsPerSample: $maxBitsPerSample, '
        'minChannels: $minChannels, '
        'maxChannels: $maxChannels, '
        'encodings: $encodings)';
  }

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        other is PcmCapability &&
            _sameIntSet(sampleRatesHz, other.sampleRatesHz) &&
            minSampleRateHz == other.minSampleRateHz &&
            maxSampleRateHz == other.maxSampleRateHz &&
            _sameIntSet(bitsPerSample, other.bitsPerSample) &&
            minBitsPerSample == other.minBitsPerSample &&
            maxBitsPerSample == other.maxBitsPerSample &&
            _sameIntSet(channels, other.channels) &&
            minChannels == other.minChannels &&
            maxChannels == other.maxChannels &&
            _sameEncodingSet(encodings, other.encodings);
  }

  @override
  int get hashCode => Object.hash(
        Object.hashAll(sampleRatesHz.toList()..sort()),
        minSampleRateHz,
        maxSampleRateHz,
        Object.hashAll(bitsPerSample.toList()..sort()),
        minBitsPerSample,
        maxBitsPerSample,
        Object.hashAll(channels.toList()..sort()),
        minChannels,
        maxChannels,
        Object.hashAll(encodings.toList()..sort((a, b) => a.index - b.index)),
      );
}

bool _sameIntSet(Set<int> a, Set<int> b) {
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

bool _sameEncodingSet(Set<PcmEncoding> a, Set<PcmEncoding> b) {
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
