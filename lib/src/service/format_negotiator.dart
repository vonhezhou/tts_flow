import '../core/tts_errors.dart';
import '../core/tts_models.dart';

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

  int _pickSampleRate(
    Set<int> sampleRates, {
    int? preferredSampleRateHz,
  }) {
    if (preferredSampleRateHz != null &&
        sampleRates.contains(preferredSampleRateHz)) {
      return preferredSampleRateHz;
    }
    return _pickMaxInt(sampleRates);
  }

  int? _resolveSampleRate({
    required PcmCapability engine,
    required PcmCapability output,
    int? preferredSampleRateHz,
  }) {
    if (preferredSampleRateHz != null &&
        engine.supportsSampleRateHz(preferredSampleRateHz) &&
        output.supportsSampleRateHz(preferredSampleRateHz)) {
      return preferredSampleRateHz;
    }

    if (engine.hasDiscreteSampleRates && output.hasDiscreteSampleRates) {
      final shared = engine.sampleRatesHz.intersection(output.sampleRatesHz);
      if (shared.isEmpty) {
        return null;
      }
      return _pickSampleRate(shared,
          preferredSampleRateHz: preferredSampleRateHz);
    }

    if (engine.hasDiscreteSampleRates) {
      final candidates =
          engine.sampleRatesHz.where(output.supportsSampleRateHz).toSet();
      if (candidates.isEmpty) {
        return null;
      }
      return _pickSampleRate(
        candidates,
        preferredSampleRateHz: preferredSampleRateHz,
      );
    }

    if (output.hasDiscreteSampleRates) {
      final candidates =
          output.sampleRatesHz.where(engine.supportsSampleRateHz).toSet();
      if (candidates.isEmpty) {
        return null;
      }
      return _pickSampleRate(
        candidates,
        preferredSampleRateHz: preferredSampleRateHz,
      );
    }

    final engineMin = engine.minSampleRateHz ?? wavMinSampleRateHz;
    final engineMax = engine.maxSampleRateHz ?? wavMaxSampleRateHz;
    final outputMin = output.minSampleRateHz ?? wavMinSampleRateHz;
    final outputMax = output.maxSampleRateHz ?? wavMaxSampleRateHz;

    final minShared = engineMin > outputMin ? engineMin : outputMin;
    final maxShared = engineMax < outputMax ? engineMax : outputMax;
    if (minShared > maxShared) {
      return null;
    }
    return maxShared;
  }

  int? _resolveBitsPerSample({
    required PcmCapability engine,
    required PcmCapability output,
  }) {
    if (engine.hasDiscreteBitsPerSample && output.hasDiscreteBitsPerSample) {
      final shared = engine.bitsPerSample.intersection(output.bitsPerSample);
      if (shared.isEmpty) {
        return null;
      }
      return _pickMaxInt(shared);
    }

    if (engine.hasDiscreteBitsPerSample) {
      final candidates =
          engine.bitsPerSample.where(output.supportsBitsPerSample).toSet();
      if (candidates.isEmpty) {
        return null;
      }
      return _pickMaxInt(candidates);
    }

    if (output.hasDiscreteBitsPerSample) {
      final candidates =
          output.bitsPerSample.where(engine.supportsBitsPerSample).toSet();
      if (candidates.isEmpty) {
        return null;
      }
      return _pickMaxInt(candidates);
    }

    final engineMin = engine.minBitsPerSample ?? wavMinBitsPerSample;
    final engineMax = engine.maxBitsPerSample ?? wavMaxBitsPerSample;
    final outputMin = output.minBitsPerSample ?? wavMinBitsPerSample;
    final outputMax = output.maxBitsPerSample ?? wavMaxBitsPerSample;

    final minShared = engineMin > outputMin ? engineMin : outputMin;
    final maxShared = engineMax < outputMax ? engineMax : outputMax;
    if (minShared > maxShared) {
      return null;
    }
    return maxShared;
  }

  int? _resolveChannelCount({
    required PcmCapability engine,
    required PcmCapability output,
  }) {
    if (engine.hasDiscreteChannels && output.hasDiscreteChannels) {
      final shared = engine.channels.intersection(output.channels);
      if (shared.isEmpty) {
        return null;
      }
      return _pickMaxInt(shared);
    }

    if (engine.hasDiscreteChannels) {
      final candidates =
          engine.channels.where(output.supportsChannelCount).toSet();
      if (candidates.isEmpty) {
        return null;
      }
      return _pickMaxInt(candidates);
    }

    if (output.hasDiscreteChannels) {
      final candidates =
          output.channels.where(engine.supportsChannelCount).toSet();
      if (candidates.isEmpty) {
        return null;
      }
      return _pickMaxInt(candidates);
    }

    final engineMin = engine.minChannels ?? wavMinChannels;
    final engineMax = engine.maxChannels ?? wavMaxChannels;
    final outputMin = output.minChannels ?? wavMinChannels;
    final outputMax = output.maxChannels ?? wavMaxChannels;

    final minShared = engineMin > outputMin ? engineMin : outputMin;
    final maxShared = engineMax < outputMax ? engineMax : outputMax;
    if (minShared > maxShared) {
      return null;
    }
    return maxShared;
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
