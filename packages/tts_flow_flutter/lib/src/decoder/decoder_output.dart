import 'dart:typed_data';

import 'package:audio_decoder/audio_decoder.dart';
import 'package:tts_flow_dart/tts_flow_dart.dart';

/// A [TtsOutput] implementation that decodes compressed audio formats
/// (MP3, AAC, Opus) to PCM using the audio_decoder package.
///
/// This output accepts any supported audio format and decodes it to
/// a PCM format negotiated with [output] or specified by [pcmFormat],
/// then forwards the decoded chunks to [output].
final class Decoder implements TtsOutput {
  /// Creates a new [Decoder] instance.
  ///
  /// [outputId] is the unique identifier for this decoder.
  /// [output] is the downstream output that receives decoded PCM chunks.
  /// [pcmFormat] optionally specifies the target PCM format.
  ///   If not specified, the format will be negotiated with [output].
  ///   If specified, this format will be used regardless of
  ///   [output]'s capabilities.
  Decoder({
    required this.outputId,
    required this.output,
    this.pcmFormat,
    this.defaultPcmFormat = const PcmDescriptor.s16Mono24KHz(),
  });

  @override
  final String outputId;

  /// The downstream output that receives decoded PCM chunks.
  final TtsOutput output;

  /// Optional target PCM descriptor. If specified, the decoder will use this
  /// format instead of negotiating with [output].
  final PcmDescriptor? pcmFormat;

  /// The default PCM format to use if [Decoder] and [Decoder.output]
  /// are open-ended and can not agree on a fixed format.
  final PcmDescriptor defaultPcmFormat;

  final _formatNegotiator = const TtsFormatNegotiator();

  @override
  Set<AudioCapability> get inAudioCapabilities {
    return {
      PcmCapability.wav(),
      const Mp3Capability(),
      const OpusCapability(),
      const AacCapability(),
    };
  }

  /// the decoder only supports PCM output.
  Set<AudioCapability> get outAudioCapabilities {
    return {
      if (pcmFormat != null)
        PcmCapability(
          sampleRatesHz: {pcmFormat!.sampleRateHz},
          bitsPerSample: {pcmFormat!.bitsPerSample},
          channels: {pcmFormat!.channels},
          encodings: {pcmFormat!.encoding},
        )
      else
        PcmCapability.wav(),
    };
  }

  TtsOutputSession? _session;
  BytesBuilder? _buffer;
  TtsAudioSpec? _negotiatedSpec;

  @override
  Future<void> init() async {
    await output.init();
  }

  @override
  Future<void> initSession(TtsOutputSession session) async {
    _session = session;
    _buffer = BytesBuilder(copy: false);

    _negotiatedSpec = _resolveAudioSpec(requestId: session.requestId);

    final outputSession = session.copyWith(
      audioSpec: _negotiatedSpec,
    );

    await output.initSession(outputSession);
  }

  int _chunkSequenceNumber = 0;

  @override
  Future<void> consumeChunk(TtsChunk chunk) async {
    final session = _session;
    final buffer = _buffer;
    if (session == null || buffer == null) {
      throw StateError('Decoder session is not initialized.');
    }
    if (chunk.requestId != session.requestId) {
      throw StateError('Chunk requestId does not match active session.');
    }

    if (chunk is! TtsAudioChunk) {
      await output.consumeChunk(chunk);
      return;
    }

    final negotiatedSpec = _negotiatedSpec;
    if (negotiatedSpec == null) {
      throw StateError('Negotiated spec not available.');
    }

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
          chunk.bytes,
          formatHint: 'pcm',
          sampleRate: targetPcm.sampleRateHz,
          channels: targetPcm.channels,
          bitDepth: targetPcm.bitsPerSample,
          includeHeader: false,
        );
      } else {
        decodedPcmBytes = chunk.bytes;
      }
    } else {
      final formatHint = session.audioSpec.format.name;
      decodedPcmBytes = await AudioDecoder.convertToWavBytes(
        chunk.bytes,
        formatHint: formatHint,
        sampleRate: negotiatedSpec.requirePcm.sampleRateHz,
        channels: negotiatedSpec.requirePcm.channels,
        bitDepth: negotiatedSpec.requirePcm.bitsPerSample,
        includeHeader: false,
      );
    }

    final decodedChunk = TtsAudioChunk(
      requestId: session.requestId,
      sequenceNumber: _chunkSequenceNumber++,
      bytes: decodedPcmBytes,
      audioSpec: negotiatedSpec,
      isLastChunk: chunk.isLastChunk,
      timestamp: DateTime.now(),
    );

    await output.consumeChunk(decodedChunk);
  }

  @override
  Future<AudioArtifact> finalizeSession() async {
    _session = null;
    _buffer = null;
    _negotiatedSpec = null;
    _chunkSequenceNumber = 0;

    return output.finalizeSession();
  }

  @override
  Future<void> onCancelSession(SynthesisControl control) async {
    await output.onCancelSession(control);
    _session = null;
    _buffer = null;
    _negotiatedSpec = null;
    _chunkSequenceNumber = 0;
  }

  @override
  Future<void> dispose() async {
    await output.dispose();
    _session = null;
    _buffer = null;
    _negotiatedSpec = null;
    _chunkSequenceNumber = 0;
  }

  /// for test only
  TtsAudioSpec resolveAudioSpecForTest(String requestId) {
    return _resolveAudioSpec(requestId: requestId);
  }

  TtsAudioSpec _resolveAudioSpec({required String requestId}) {
    final spec = _formatNegotiator.negotiateSpec(
      engineCapabilities: outAudioCapabilities,
      outputCapabilities: output.inAudioCapabilities,
      preferredOrder: TtsAudioFormat.values,
      preferredFormat: TtsAudioFormat.pcm,
      requestId: requestId,
    );

    if (spec.format == TtsAudioFormat.pcm && spec.pcm == null) {
      return TtsAudioSpec.pcm(defaultPcmFormat);
    }

    return spec;
  }
}
