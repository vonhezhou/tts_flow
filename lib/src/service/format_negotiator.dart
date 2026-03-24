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
        final sampleRates = e.sampleRatesHz.intersection(o.sampleRatesHz);
        final bits = e.bitsPerSample.intersection(o.bitsPerSample);
        final channels = e.channels.intersection(o.channels);
        final encodings = e.encodings.intersection(o.encodings);

        if (sampleRates.isEmpty ||
            bits.isEmpty ||
            channels.isEmpty ||
            encodings.isEmpty) {
          continue;
        }

        final sampleRateHz = _pickSampleRate(
          sampleRates,
          preferredSampleRateHz: preferredSampleRateHz,
        );
        final bitsPerSample = _pickMaxInt(bits);
        final channelCount = _pickMaxInt(channels);
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
