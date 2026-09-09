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

  TtsOutputWriteContext? _writeContext;
  BytesBuilder? _buffer;
  TtsAudioSpec? _negotiatedSpec;

  @override
  Future<void> init() async {
    await output.init();
  }

  @override
  Future<void> startWrite(TtsOutputWriteContext writeContext) async {
    _writeContext = writeContext;
    _buffer = BytesBuilder(copy: false);

    _negotiatedSpec = _resolveAudioSpec(requestKey: writeContext.requestKey);

    final downstreamWriteContext = writeContext.copyWith(
      audioSpec: _negotiatedSpec,
    );

    await output.startWrite(downstreamWriteContext);
  }

  int _chunkSequenceNumber = 0;

  @override
  Future<void> writeChunk(TtsChunk chunk) async {
    final writeContext = _writeContext;
    final buffer = _buffer;
    if (writeContext == null || buffer == null) {
      throw StateError('Decoder write has not started.');
    }
    if (chunk.requestKey != writeContext.requestKey) {
      throw StateError('Chunk requestKey does not match active write.');
    }

    if (chunk is! TtsAudioChunk) {
      await output.writeChunk(chunk);
      return;
    }

    final negotiatedSpec = _negotiatedSpec;
    if (negotiatedSpec == null) {
      throw StateError('Negotiated spec not available.');
    }

    Uint8List decodedPcmBytes;
    if (writeContext.audioSpec.format == TtsAudioFormat.pcm) {
      final inputPcm = writeContext.audioSpec.requirePcm;
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
      final formatHint = writeContext.audioSpec.format.name;
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
      requestKey: writeContext.requestKey,
      sequenceNumber: _chunkSequenceNumber++,
      bytes: decodedPcmBytes,
      audioSpec: negotiatedSpec,
      isLastChunk: chunk.isLastChunk,
      timestamp: DateTime.now(),
    );

    await output.writeChunk(decodedChunk);
  }

  @override
  Future<AudioArtifact> finishWrite() async {
    _writeContext = null;
    _buffer = null;
    _negotiatedSpec = null;
    _chunkSequenceNumber = 0;

    return output.finishWrite();
  }

  @override
  Future<void> cancelWrite(SynthesisControl control) async {
    await output.cancelWrite(control);
    _writeContext = null;
    _buffer = null;
    _negotiatedSpec = null;
    _chunkSequenceNumber = 0;
  }

  @override
  Future<void> dispose() async {
    await output.dispose();
    _writeContext = null;
    _buffer = null;
    _negotiatedSpec = null;
    _chunkSequenceNumber = 0;
  }

  /// for test only
  TtsAudioSpec resolveAudioSpecForTest(String requestKey) {
    return _resolveAudioSpec(requestKey: requestKey);
  }

  TtsAudioSpec _resolveAudioSpec({required String requestKey}) {
    final spec = _formatNegotiator.negotiateSpec(
      engineCapabilities: outAudioCapabilities,
      outputCapabilities: output.inAudioCapabilities,
      preferredOrder: TtsAudioFormat.values,
      preferredFormat: TtsAudioFormat.pcm,
      requestKey: requestKey,
    );

    if (spec.format == TtsAudioFormat.pcm && spec.pcm == null) {
      return TtsAudioSpec.pcm(defaultPcmFormat);
    }

    return spec;
  }
}
