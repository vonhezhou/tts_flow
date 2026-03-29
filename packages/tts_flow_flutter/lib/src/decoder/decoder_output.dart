import 'dart:typed_data';

import 'package:audio_decoder/audio_decoder.dart';
import 'package:tts_flow_dart/tts_flow_dart.dart';

/// A [TtsOutput] implementation that decodes compressed audio formats
/// (MP3, AAC, Opus) to PCM using the audio_decoder package.
///
/// This output accepts any supported audio format and decodes it to
/// a PCM format negotiated with [output], then forwards the decoded
/// chunks to [output].
final class Decoder implements TtsOutput {
  /// Creates a new [Decoder] instance.
  ///
  /// [outputId] is the unique identifier for this decoder.
  /// [output] is the downstream output that receives decoded PCM chunks.
  Decoder({
    required this.outputId,
    required this.output,
  });

  @override
  final String outputId;

  /// The downstream output that receives decoded PCM chunks.
  final TtsOutput output;

  @override
  Set<AudioCapability> get acceptedCapabilities {
    final pcmCapabilities = output.acceptedCapabilities
        .whereType<PcmCapability>()
        .toList();

    if (pcmCapabilities.isEmpty) {
      return {
        PcmCapability.wav(),
        const Mp3Capability(),
        const OpusCapability(),
        const AacCapability(),
      };
    }

    final intersectedPcm = _intersectPcmCapabilities(pcmCapabilities);

    return {
      if (intersectedPcm != null) intersectedPcm else PcmCapability.wav(),
      const Mp3Capability(),
      const OpusCapability(),
      const AacCapability(),
    };
  }

  TtsOutputSession? _session;
  BytesBuilder? _buffer;
  TtsAudioSpec? _negotiatedSpec;

  PcmCapability? _intersectPcmCapabilities(List<PcmCapability> capabilities) {
    if (capabilities.isEmpty) {
      return null;
    }

    Set<int>? sampleRates;
    Set<int>? bitDepths;
    Set<int>? channels;
    Set<PcmEncoding>? encodings;

    for (final capability in capabilities) {
      if (capability.sampleRatesHz != null) {
        sampleRates = sampleRates == null
            ? Set<int>.from(capability.sampleRatesHz!)
            : sampleRates.intersection(capability.sampleRatesHz!);
      }
      if (capability.bitsPerSample != null) {
        bitDepths = bitDepths == null
            ? Set<int>.from(capability.bitsPerSample!)
            : bitDepths.intersection(capability.bitsPerSample!);
      }
      if (capability.channels != null) {
        channels = channels == null
            ? Set<int>.from(capability.channels!)
            : channels.intersection(capability.channels!);
      }
      if (capability.encodings != null) {
        encodings = encodings == null
            ? Set<PcmEncoding>.from(capability.encodings!)
            : encodings.intersection(capability.encodings!);
      }
    }

    if (sampleRates != null && sampleRates.isEmpty) {
      return null;
    }
    if (bitDepths != null && bitDepths.isEmpty) {
      return null;
    }
    if (channels != null && channels.isEmpty) {
      return null;
    }
    if (encodings != null && encodings.isEmpty) {
      return null;
    }

    return PcmCapability(
      sampleRatesHz: sampleRates,
      bitsPerSample: bitDepths,
      channels: channels,
      encodings: encodings,
    );
  }

  @override
  Future<void> init() async {
    await output.init();
  }

  @override
  Future<void> initSession(TtsOutputSession session) async {
    _session = session;
    _buffer = BytesBuilder(copy: false);

    final outputPcmCapabilities = output.acceptedCapabilities
        .whereType<PcmCapability>()
        .toList();

    if (outputPcmCapabilities.isEmpty) {
      _negotiatedSpec = const TtsAudioSpec.pcm(
        PcmDescriptor(
          sampleRateHz: 16000,
          channels: 1,
          bitsPerSample: 16,
        ),
      );
    } else {
      final intersectedPcm = _intersectPcmCapabilities(outputPcmCapabilities);
      if (intersectedPcm != null) {
        final sampleRate = intersectedPcm.sampleRatesHz?.first ?? 16000;
        final channels = intersectedPcm.channels?.first ?? 1;
        final bitsPerSample = intersectedPcm.bitsPerSample?.first ?? 16;

        _negotiatedSpec = TtsAudioSpec.pcm(
          PcmDescriptor(
            sampleRateHz: sampleRate,
            channels: channels,
            bitsPerSample: bitsPerSample,
          ),
        );
      } else {
        _negotiatedSpec = const TtsAudioSpec.pcm(
          PcmDescriptor(
            sampleRateHz: 16000,
            channels: 1,
            bitsPerSample: 16,
          ),
        );
      }
    }

    await output.initSession(session);
  }

  @override
  Future<void> consumeChunk(TtsChunk chunk) async {
    final session = _session;
    final buffer = _buffer;
    if (session == null || buffer == null) {
      throw StateError('DecoderOutput session is not initialized.');
    }
    if (chunk.requestId != session.requestId) {
      throw StateError('Chunk requestId does not match active session.');
    }
    buffer.add(chunk.bytes);
  }

  @override
  Future<AudioArtifact> finalizeSession() async {
    final session = _session;
    final buffer = _buffer;
    final negotiatedSpec = _negotiatedSpec;
    if (session == null || buffer == null || negotiatedSpec == null) {
      throw StateError('Decoder session is not initialized.');
    }

    final inputBytes = buffer.takeBytes();

    Uint8List decodedPcmBytes;

    if (session.audioSpec.format == TtsAudioFormat.pcm) {
      final inputPcm = session.audioSpec.requirePcm;
      final targetPcm = negotiatedSpec.requirePcm;
      final needsConversion =
          inputPcm.sampleRateHz != targetPcm.sampleRateHz ||
          inputPcm.channels != targetPcm.channels ||
          inputPcm.bitsPerSample != targetPcm.bitsPerSample;

      if (needsConversion) {
        decodedPcmBytes = await AudioDecoder.convertToWavBytes(
          inputBytes,
          formatHint: 'pcm',
          sampleRate: targetPcm.sampleRateHz,
          channels: targetPcm.channels,
          bitDepth: targetPcm.bitsPerSample,
          includeHeader: false,
        );
      } else {
        decodedPcmBytes = inputBytes;
      }
    } else {
      final formatHint = session.audioSpec.format.name;
      decodedPcmBytes = await AudioDecoder.convertToWavBytes(
        inputBytes,
        formatHint: formatHint,
        sampleRate: negotiatedSpec.requirePcm.sampleRateHz,
        channels: negotiatedSpec.requirePcm.channels,
        bitDepth: negotiatedSpec.requirePcm.bitsPerSample,
        includeHeader: false,
      );
    }

    final decodedChunk = TtsChunk(
      requestId: session.requestId,
      sequenceNumber: 0,
      bytes: decodedPcmBytes,
      audioSpec: negotiatedSpec,
      isLastChunk: true,
      timestamp: DateTime.now(),
    );

    await output.consumeChunk(decodedChunk);
    final artifact = await output.finalizeSession();

    _session = null;
    _buffer = null;
    _negotiatedSpec = null;

    return artifact;
  }

  @override
  Future<void> onCancelSession(SynthesisControl control) async {
    await output.onCancelSession(control);
    _session = null;
    _buffer = null;
    _negotiatedSpec = null;
  }

  @override
  Future<void> dispose() async {
    await output.dispose();
    _session = null;
    _buffer = null;
    _negotiatedSpec = null;
  }
}
