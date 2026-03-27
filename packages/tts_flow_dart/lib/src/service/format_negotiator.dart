import 'package:tts_flow_dart/src/base/pcm_descriptor.dart';
import 'package:tts_flow_dart/src/core/audio_capability.dart';
import 'package:tts_flow_dart/src/core/audio_spec.dart';

import '../core/tts_errors.dart';

final class TtsFormatNegotiator {
  const TtsFormatNegotiator();

  TtsAudioSpec negotiateSpec({
    required Set<AudioCapability> engineCapabilities,
    required Set<AudioCapability> outputCapabilities,
    required List<TtsAudioFormat> preferredOrder,
    required String requestId,
    TtsAudioFormat? preferredFormat,
    int? preferredSampleRateHz,
  }) {
    final intersection = _intersectFormats(
      engineCapabilities,
      outputCapabilities,
    );

    if (intersection.isEmpty) {
      throw TtsError(
        code: TtsErrorCode.formatNegotiationFailed,
        message: 'Engine and output do not share a common audio format. '
            'engineFormats: ${_sortedFormats(engineCapabilities)}, '
            'outputFormats: ${_sortedFormats(outputCapabilities)}, '
            'preferredFormat: $preferredFormat, '
            'preferredOrder: $preferredOrder',
        requestId: requestId,
      );
    }

    final selectedFormat = _resolveFormat(
      intersection: intersection,
      preferredOrder: preferredOrder,
      preferredFormat: preferredFormat,
      requestId: requestId,
    );

    if (selectedFormat == TtsAudioFormat.mp3) {
      return const TtsAudioSpec.mp3();
    }
    if (selectedFormat == TtsAudioFormat.opus) {
      return const TtsAudioSpec.opus();
    }
    if (selectedFormat == TtsAudioFormat.aac) {
      return const TtsAudioSpec.aac();
    }

    final pcmDescriptor = _resolvePcmDescriptor(
      engineCapabilities: engineCapabilities,
      outputCapabilities: outputCapabilities,
      requestId: requestId,
      preferredSampleRateHz: preferredSampleRateHz,
    );
    return TtsAudioSpec.pcm(pcmDescriptor);
  }

  TtsAudioFormat negotiate({
    required Set<TtsAudioFormat> engineFormats,
    required Set<TtsAudioFormat> outputFormats,
    required List<TtsAudioFormat> preferredOrder,
    required String requestId,
    TtsAudioFormat? preferredFormat,
  }) {
    final resolved = negotiateSpec(
      engineCapabilities: engineFormats
          .map((format) => SimpleFormatCapability(format: format))
          .toSet(),
      outputCapabilities: outputFormats
          .map((format) => SimpleFormatCapability(format: format))
          .toSet(),
      preferredOrder: preferredOrder,
      requestId: requestId,
      preferredFormat: preferredFormat,
    );
    return resolved.format;
  }

  Set<TtsAudioFormat> _intersectFormats(
    Set<AudioCapability> engineCapabilities,
    Set<AudioCapability> outputCapabilities,
  ) {
    final engineFormats = engineCapabilities.map((c) => c.format).toSet();
    final outputFormats = outputCapabilities.map((c) => c.format).toSet();
    return engineFormats.intersection(outputFormats);
  }

  TtsAudioFormat _resolveFormat({
    required Set<TtsAudioFormat> intersection,
    required List<TtsAudioFormat> preferredOrder,
    required String requestId,
    TtsAudioFormat? preferredFormat,
  }) {
    if (preferredFormat != null && intersection.contains(preferredFormat)) {
      return preferredFormat;
    }

    for (final format in preferredOrder) {
      if (intersection.contains(format)) {
        return format;
      }
    }

    throw TtsError(
      code: TtsErrorCode.formatNegotiationFailed,
      message: 'No compatible format found using preferred format order. '
          'sharedFormats: ${_sortedFormatSet(intersection)}, '
          'preferredFormat: $preferredFormat, '
          'preferredOrder: $preferredOrder',
      requestId: requestId,
    );
  }

  PcmDescriptor _resolvePcmDescriptor({
    required Set<AudioCapability> engineCapabilities,
    required Set<AudioCapability> outputCapabilities,
    required String requestId,
    int? preferredSampleRateHz,
  }) {
    final enginePcm = engineCapabilities.whereType<PcmCapability>().toList();
    final outputPcm = outputCapabilities.whereType<PcmCapability>().toList();

    for (final e in enginePcm) {
      for (final o in outputPcm) {
        final encodings = _resolveEncodings(engine: e, output: o);

        if (encodings.isEmpty) {
          continue;
        }

        final sampleRateHz = _resolveSampleRate(
          engine: e,
          output: o,
          preferredSampleRateHz: preferredSampleRateHz,
        );
        if (sampleRateHz == null) {
          continue;
        }
        final bitsPerSample = _resolveBitsPerSample(engine: e, output: o);
        if (bitsPerSample == null) {
          continue;
        }
        final channelCount = _resolveChannelCount(engine: e, output: o);
        if (channelCount == null) {
          continue;
        }
        final encoding = _pickEncoding(encodings);

        return PcmDescriptor(
          sampleRateHz: sampleRateHz,
          bitsPerSample: bitsPerSample,
          channels: channelCount,
          encoding: encoding,
        );
      }
    }

    throw TtsError(
      code: TtsErrorCode.formatNegotiationFailed,
      message: 'PCM format selected but no compatible PCM descriptor exists. '
          'preferredSampleRateHz: $preferredSampleRateHz, '
          'enginePcmCapabilities: $enginePcm, '
          'outputPcmCapabilities: $outputPcm',
      requestId: requestId,
    );
  }

  int? _resolveSampleRate({
    required PcmCapability engine,
    required PcmCapability output,
    int? preferredSampleRateHz,
  }) {
    return _resolveIntDimension(
      engineDiscrete: engine.sampleRatesHz,
      engineSupports: engine.supportsSampleRateHz,
      outputDiscrete: output.sampleRatesHz,
      outputSupports: output.supportsSampleRateHz,
      domainMax: wavMaxSampleRateHz,
      preferredValue: preferredSampleRateHz,
    );
  }

  int? _resolveBitsPerSample({
    required PcmCapability engine,
    required PcmCapability output,
  }) {
    return _resolveIntDimension(
      engineDiscrete: engine.bitsPerSample,
      engineSupports: engine.supportsBitsPerSample,
      outputDiscrete: output.bitsPerSample,
      outputSupports: output.supportsBitsPerSample,
      domainMax: wavMaxBitsPerSample,
    );
  }

  int? _resolveChannelCount({
    required PcmCapability engine,
    required PcmCapability output,
  }) {
    return _resolveIntDimension(
      engineDiscrete: engine.channels,
      engineSupports: engine.supportsChannelCount,
      outputDiscrete: output.channels,
      outputSupports: output.supportsChannelCount,
      domainMax: wavMaxChannels,
    );
  }

  Set<PcmEncoding> _resolveEncodings({
    required PcmCapability engine,
    required PcmCapability output,
  }) {
    final engineEncodings = engine.encodings;
    final outputEncodings = output.encodings;

    if (engineEncodings != null && engineEncodings.isEmpty) {
      return const <PcmEncoding>{};
    }
    if (outputEncodings != null && outputEncodings.isEmpty) {
      return const <PcmEncoding>{};
    }

    if (engineEncodings != null && outputEncodings != null) {
      return engineEncodings.intersection(outputEncodings);
    }

    if (engineEncodings != null) {
      return Set<PcmEncoding>.from(
        engineEncodings.where(output.supportsEncoding),
      );
    }

    if (outputEncodings != null) {
      return Set<PcmEncoding>.from(
        outputEncodings.where(engine.supportsEncoding),
      );
    }

    return Set<PcmEncoding>.from(PcmEncoding.values);
  }

  int? _resolveIntDimension({
    required Set<int>? engineDiscrete,
    required bool Function(int value) engineSupports,
    required Set<int>? outputDiscrete,
    required bool Function(int value) outputSupports,
    required int domainMax,
    int? preferredValue,
  }) {
    if (engineDiscrete != null && engineDiscrete.isEmpty) {
      return null;
    }
    if (outputDiscrete != null && outputDiscrete.isEmpty) {
      return null;
    }

    if (preferredValue != null &&
        engineSupports(preferredValue) &&
        outputSupports(preferredValue)) {
      return preferredValue;
    }

    if (engineDiscrete != null && outputDiscrete != null) {
      final shared = engineDiscrete.intersection(outputDiscrete);
      if (shared.isEmpty) {
        return null;
      }
      return _pickPreferredOrMax(shared, preferredValue: preferredValue);
    }

    if (engineDiscrete != null) {
      final candidates = engineDiscrete.where(outputSupports).toSet();
      if (candidates.isEmpty) {
        return null;
      }
      return _pickPreferredOrMax(candidates, preferredValue: preferredValue);
    }

    if (outputDiscrete != null) {
      final candidates = outputDiscrete.where(engineSupports).toSet();
      if (candidates.isEmpty) {
        return null;
      }
      return _pickPreferredOrMax(candidates, preferredValue: preferredValue);
    }

    return domainMax;
  }

  int _pickPreferredOrMax(
    Set<int> values, {
    int? preferredValue,
  }) {
    if (preferredValue != null && values.contains(preferredValue)) {
      return preferredValue;
    }
    return _pickMaxInt(values);
  }

  int _pickMaxInt(Set<int> values) {
    return values.reduce((a, b) => a > b ? a : b);
  }

  PcmEncoding _pickEncoding(Set<PcmEncoding> values) {
    const preference = <PcmEncoding>[
      PcmEncoding.signedInt,
      PcmEncoding.float,
      PcmEncoding.unsignedInt,
    ];

    for (final candidate in preference) {
      if (values.contains(candidate)) {
        return candidate;
      }
    }
    return values.first;
  }

  List<TtsAudioFormat> _sortedFormats(Set<AudioCapability> capabilities) {
    return _sortedFormatSet(capabilities.map((c) => c.format).toSet());
  }

  List<TtsAudioFormat> _sortedFormatSet(Set<TtsAudioFormat> formats) {
    final sorted = formats.toList();
    sorted.sort((a, b) => a.index.compareTo(b.index));
    return sorted;
  }
}
