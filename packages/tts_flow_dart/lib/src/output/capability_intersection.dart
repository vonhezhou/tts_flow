import 'package:tts_flow_dart/src/base/pcm_descriptor.dart';
import 'package:tts_flow_dart/src/core/audio_capability.dart';
import 'package:tts_flow_dart/src/core/audio_spec.dart';

/// Returns the intersection of two [AudioCapability] sets.
///
/// A capability is included in the result only if both sides support the same
/// format. For [PcmCapability], the allowed values for each field are narrowed
/// to the common subset; `null` means "any value within WAV limits".
Set<AudioCapability> intersectCapabilities(
  Set<AudioCapability> left,
  Set<AudioCapability> right,
) {
  final rightByFormat = <TtsAudioFormat, List<AudioCapability>>{};
  for (final capability in right) {
    rightByFormat
        .putIfAbsent(capability.format, () => <AudioCapability>[])
        .add(capability);
  }

  final result = <AudioCapability>{};
  for (final leftCapability in left) {
    final candidates = rightByFormat[leftCapability.format];
    if (candidates == null || candidates.isEmpty) {
      continue;
    }

    if (leftCapability.format != TtsAudioFormat.pcm) {
      result.add(_formatToCapability(leftCapability.format));
      continue;
    }

    if (leftCapability is! PcmCapability) {
      continue;
    }

    for (final rightCapability in candidates) {
      if (rightCapability is! PcmCapability) {
        continue;
      }
      final intersected = _intersectPcmCapabilities(
        leftCapability,
        rightCapability,
      );
      if (intersected != null) {
        result.add(intersected);
      }
    }
  }

  return result;
}

PcmCapability? _intersectPcmCapabilities(
  PcmCapability left,
  PcmCapability right,
) {
  final sampleRate = _intersectIntConstraint(
    leftValues: left.sampleRatesHz,
    rightValues: right.sampleRatesHz,
  );
  if (sampleRate != null && sampleRate.isEmpty) {
    return null;
  }

  final bitDepth = _intersectIntConstraint(
    leftValues: left.bitsPerSample,
    rightValues: right.bitsPerSample,
  );
  if (bitDepth != null && bitDepth.isEmpty) {
    return null;
  }

  final channels = _intersectIntConstraint(
    leftValues: left.channels,
    rightValues: right.channels,
  );
  if (channels != null && channels.isEmpty) {
    return null;
  }

  final encodings = _intersectEncodings(
    leftValues: left.encodings,
    rightValues: right.encodings,
  );
  if (encodings.isEmpty) {
    return null;
  }

  return PcmCapability(
    sampleRatesHz: sampleRate,
    bitsPerSample: bitDepth,
    channels: channels,
    encodings: encodings,
  );
}

/// Intersects two optional int constraint sets.
///
/// Returns `null` when both sides are unconstrained (accept any value).
/// Returns an empty set when the constraints share no common values.
Set<int>? _intersectIntConstraint({
  required Set<int>? leftValues,
  required Set<int>? rightValues,
}) {
  if (leftValues != null && leftValues.isEmpty) {
    return const <int>{};
  }
  if (rightValues != null && rightValues.isEmpty) {
    return const <int>{};
  }

  if (leftValues == null && rightValues == null) {
    return null;
  }

  if (leftValues == null) {
    return Set<int>.from(rightValues!);
  }
  if (rightValues == null) {
    return Set<int>.from(leftValues);
  }

  return leftValues.intersection(rightValues);
}

Set<PcmEncoding> _intersectEncodings({
  required Set<PcmEncoding>? leftValues,
  required Set<PcmEncoding>? rightValues,
}) {
  if (leftValues != null && leftValues.isEmpty) {
    return const <PcmEncoding>{};
  }
  if (rightValues != null && rightValues.isEmpty) {
    return const <PcmEncoding>{};
  }

  if (leftValues == null && rightValues == null) {
    return Set<PcmEncoding>.from(PcmEncoding.values);
  }
  if (leftValues == null) {
    return Set<PcmEncoding>.from(rightValues!);
  }
  if (rightValues == null) {
    return Set<PcmEncoding>.from(leftValues);
  }

  return leftValues.intersection(rightValues);
}

AudioCapability _formatToCapability(TtsAudioFormat format) {
  return switch (format) {
    TtsAudioFormat.pcm => PcmCapability(),
    TtsAudioFormat.mp3 => const Mp3Capability(),
    TtsAudioFormat.opus => const OpusCapability(),
    TtsAudioFormat.aac => const AacCapability(),
  };
}
