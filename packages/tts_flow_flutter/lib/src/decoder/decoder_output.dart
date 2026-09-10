import 'dart:typed_data';

import 'package:audio_decoder/audio_decoder.dart';
import 'package:tts_flow_dart/tts_flow_dart.dart';

/// Converts a complete encoded audio payload into raw PCM bytes.
///
/// This is deliberately a whole-payload operation. The bundled
/// `audio_decoder` API accepts audio-file bytes, not an incremental codec
/// stream, so decoding arbitrary network chunks independently would corrupt
/// frames split across chunk boundaries.
/// Converts one complete encoded-audio payload to raw PCM bytes.
typedef AudioPcmConverter =
    Future<Uint8List> Function({
      required Uint8List input,
      required TtsAudioSpec inputSpec,
      required PcmDescriptor outputPcm,
    });

Future<Uint8List> _convertWithPlatformAudioDecoder({
  required Uint8List input,
  required TtsAudioSpec inputSpec,
  required PcmDescriptor outputPcm,
}) {
  final String formatHint;
  final Uint8List sourceBytes;

  if (inputSpec.format == TtsAudioFormat.pcm) {
    final inputPcm = inputSpec.requirePcm;
    final header = WavHeader.fromPcmDescriptor(
      inputPcm,
      dataLengthBytes: input.length,
    ).toBytes();
    final wavBytes = BytesBuilder(copy: false)
      ..add(header)
      ..add(input);
    sourceBytes = wavBytes.takeBytes();
    formatHint = 'wav';
  } else {
    sourceBytes = input;
    formatHint = inputSpec.format.name;
  }

  return AudioDecoder.convertToWavBytes(
    sourceBytes,
    formatHint: formatHint,
    sampleRate: outputPcm.sampleRateHz,
    channels: outputPcm.channels,
    bitDepth: outputPcm.bitsPerSample,
    includeHeader: false,
  );
}

/// A [TtsOutput] implementation that decodes compressed audio formats
/// (MP3, AAC, Opus) to PCM using the audio_decoder package.
///
/// This output accepts any supported audio format and decodes it to
/// a PCM format negotiated with [output] or specified by [pcmFormat].
///
/// Compressed input is accumulated for one output write and converted when
/// that write finishes. This preserves codec frames split across arbitrary
/// network chunks. It is therefore an explicit complete-payload conversion
/// branch, not a low-latency streaming decoder; keep latency-critical playback
/// on a direct compressed-audio output.
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
    this.maxBufferedBytes = 64 * 1024 * 1024,
    AudioPcmConverter converter = _convertWithPlatformAudioDecoder,
  }) : assert(
         maxBufferedBytes == null || maxBufferedBytes > 0,
         'maxBufferedBytes must be positive or null.',
       ),
       _converter = converter;

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

  /// Maximum encoded bytes retained for a whole-payload conversion.
  ///
  /// Compressed conversion is intentionally non-streaming, so the default
  /// 64 MiB limit prevents an unexpectedly long response from retaining
  /// unbounded memory.
  /// Set this to `null` only when the caller explicitly accepts that risk.
  final int? maxBufferedBytes;

  final AudioPcmConverter _converter;

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
  bool _buffersWholeInput = false;
  int? _lastBufferedSequenceNumber;
  DateTime? _lastBufferedTimestamp;

  @override
  Future<void> init() async {
    await output.init();
  }

  @override
  Future<void> startWrite(TtsOutputWriteContext writeContext) async {
    _writeContext = writeContext;
    _negotiatedSpec = _resolveAudioSpec(requestKey: writeContext.requestKey);
    _buffersWholeInput = _requiresWholeInputConversion(
      input: writeContext.audioSpec,
      output: _negotiatedSpec!,
    );
    _buffer = _buffersWholeInput ? BytesBuilder(copy: false) : null;

    final downstreamWriteContext = writeContext.copyWith(
      audioSpec: _negotiatedSpec,
    );

    await output.startWrite(downstreamWriteContext);
  }

  int _chunkSequenceNumber = 0;

  @override
  Future<void> writeChunk(TtsChunk chunk) async {
    final writeContext = _writeContext;
    if (writeContext == null) {
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

    if (_buffersWholeInput) {
      final buffer = _buffer;
      if (buffer == null) {
        throw StateError('Decoder conversion buffer is not initialized.');
      }
      final maxBytes = maxBufferedBytes;
      final nextLength = buffer.length + chunk.bytes.length;
      if (maxBytes != null && nextLength > maxBytes) {
        throw StateError(
          'Decoder input exceeds maxBufferedBytes '
          '($nextLength > $maxBytes).',
        );
      }
      buffer.add(chunk.bytes);
      _lastBufferedSequenceNumber = chunk.sequenceNumber;
      _lastBufferedTimestamp = chunk.timestamp;
      return;
    }

    final decodedChunk = TtsAudioChunk(
      requestKey: writeContext.requestKey,
      sequenceNumber: _chunkSequenceNumber++,
      bytes: chunk.bytes,
      audioSpec: negotiatedSpec,
      isLastChunk: chunk.isLastChunk,
      timestamp: DateTime.now(),
    );

    await output.writeChunk(decodedChunk);
  }

  @override
  Future<AudioArtifact> finishWrite() async {
    final writeContext = _writeContext;
    final negotiatedSpec = _negotiatedSpec;
    if (writeContext == null || negotiatedSpec == null) {
      throw StateError('Decoder write has not started.');
    }

    try {
      final buffer = _buffer;
      if (_buffersWholeInput && buffer != null && buffer.length > 0) {
        final decodedPcmBytes = await _converter(
          input: buffer.takeBytes(),
          inputSpec: writeContext.audioSpec,
          outputPcm: negotiatedSpec.requirePcm,
        );
        await output.writeChunk(
          TtsAudioChunk(
            requestKey: writeContext.requestKey,
            sequenceNumber: _lastBufferedSequenceNumber ?? 0,
            bytes: decodedPcmBytes,
            audioSpec: negotiatedSpec,
            isLastChunk: true,
            timestamp: _lastBufferedTimestamp ?? DateTime.now(),
          ),
        );
      }
      return await output.finishWrite();
    } finally {
      _clearWriteState();
    }
  }

  @override
  Future<void> cancelWrite(SynthesisControl control) async {
    await output.cancelWrite(control);
    _clearWriteState();
  }

  @override
  Future<void> dispose() async {
    await output.dispose();
    _clearWriteState();
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

  bool _requiresWholeInputConversion({
    required TtsAudioSpec input,
    required TtsAudioSpec output,
  }) {
    if (input.format != TtsAudioFormat.pcm) {
      return true;
    }
    return input.requirePcm != output.requirePcm;
  }

  void _clearWriteState() {
    _writeContext = null;
    _buffer = null;
    _negotiatedSpec = null;
    _buffersWholeInput = false;
    _lastBufferedSequenceNumber = null;
    _lastBufferedTimestamp = null;
    _chunkSequenceNumber = 0;
  }
}
