import 'package:tts_flow_dart/src/base/audio_capability.dart';
import 'package:tts_flow_dart/src/base/audio_spec.dart';
import 'package:tts_flow_dart/src/base/pcm_descriptor.dart';

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

    if (selectedFormat != TtsAudioFormat.pcm) {
      return TtsAudioSpec(format: selectedFormat);
    }

    final pcmDescriptor = _resolvePcmDescriptor(
      engineCapabilities: engineCapabilities,
      outputCapabilities: outputCapabilities,
      requestId: requestId,
      preferredSampleRateHz: preferredSampleRateHz,
    );
    return TtsAudioSpec(
      format: TtsAudioFormat.pcm,
      pcm: pcmDescriptor,
    );
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
        final encodings = e.encodings.intersection(o.encodings);

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
      engineHasDiscrete: engine.hasDiscreteSampleRates,
      engineMin: engine.minSampleRateHz,
      engineMax: engine.maxSampleRateHz,
      engineSupports: engine.supportsSampleRateHz,
      outputDiscrete: output.sampleRatesHz,
      outputHasDiscrete: output.hasDiscreteSampleRates,
      outputMin: output.minSampleRateHz,
      outputMax: output.maxSampleRateHz,
      outputSupports: output.supportsSampleRateHz,
      domainMin: wavMinSampleRateHz,
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
      engineHasDiscrete: engine.hasDiscreteBitsPerSample,
      engineMin: engine.minBitsPerSample,
      engineMax: engine.maxBitsPerSample,
      engineSupports: engine.supportsBitsPerSample,
      outputDiscrete: output.bitsPerSample,
      outputHasDiscrete: output.hasDiscreteBitsPerSample,
      outputMin: output.minBitsPerSample,
      outputMax: output.maxBitsPerSample,
      outputSupports: output.supportsBitsPerSample,
      domainMin: wavMinBitsPerSample,
      domainMax: wavMaxBitsPerSample,
    );
  }

  int? _resolveChannelCount({
    required PcmCapability engine,
    required PcmCapability output,
  }) {
    return _resolveIntDimension(
      engineDiscrete: engine.channels,
      engineHasDiscrete: engine.hasDiscreteChannels,
      engineMin: engine.minChannels,
      engineMax: engine.maxChannels,
      engineSupports: engine.supportsChannelCount,
      outputDiscrete: output.channels,
      outputHasDiscrete: output.hasDiscreteChannels,
      outputMin: output.minChannels,
      outputMax: output.maxChannels,
      outputSupports: output.supportsChannelCount,
      domainMin: wavMinChannels,
      domainMax: wavMaxChannels,
    );
  }

  int? _resolveIntDimension({
    required Set<int> engineDiscrete,
    required bool engineHasDiscrete,
    required int? engineMin,
    required int? engineMax,
    required bool Function(int value) engineSupports,
    required Set<int> outputDiscrete,
    required bool outputHasDiscrete,
    required int? outputMin,
    required int? outputMax,
    required bool Function(int value) outputSupports,
    required int domainMin,
    required int domainMax,
    int? preferredValue,
  }) {
    if (preferredValue != null &&
        engineSupports(preferredValue) &&
        outputSupports(preferredValue)) {
      return preferredValue;
    }

    if (engineHasDiscrete && outputHasDiscrete) {
      final shared = engineDiscrete.intersection(outputDiscrete);
      if (shared.isEmpty) {
        return null;
      }
      return _pickPreferredOrMax(shared, preferredValue: preferredValue);
    }

    if (engineHasDiscrete) {
      final candidates = engineDiscrete.where(outputSupports).toSet();
      if (candidates.isEmpty) {
        return null;
      }
      return _pickPreferredOrMax(candidates, preferredValue: preferredValue);
    }

    if (outputHasDiscrete) {
      final candidates = outputDiscrete.where(engineSupports).toSet();
      if (candidates.isEmpty) {
        return null;
      }
      return _pickPreferredOrMax(candidates, preferredValue: preferredValue);
    }

    final effectiveEngineMin = engineMin ?? domainMin;
    final effectiveEngineMax = engineMax ?? domainMax;
    final effectiveOutputMin = outputMin ?? domainMin;
    final effectiveOutputMax = outputMax ?? domainMax;

    final minShared = effectiveEngineMin > effectiveOutputMin
        ? effectiveEngineMin
        : effectiveOutputMin;
    final maxShared = effectiveEngineMax < effectiveOutputMax
        ? effectiveEngineMax
        : effectiveOutputMax;
    if (minShared > maxShared) {
      return null;
    }
    return maxShared;
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
