import 'dart:async';
import 'dart:typed_data';

import 'package:just_audio/just_audio.dart';
import 'package:tts_flow_dart/tts_flow_dart.dart';

/// other source did not work.
// ignore: experimental_member_use
class ChunkAudioSource extends StreamAudioSource {
  ///
  ChunkAudioSource({
    required this.audioSpec,
    required this.playbackId,
    required this.requestId,
    required this.isTerminalSegment,
  });

  final List<int> _buffer = [];

  /// The audio spec (format + optional PCM descriptor) for this segment.
  final TtsAudioSpec audioSpec;

  /// Convenience accessor for the audio format.
  TtsAudioFormat get format => audioSpec.format;

  /// The playback identifier for the session this segment belongs to.
  final String playbackId;

  /// The request identifier for the TTS request this segment belongs to.
  final String requestId;

  /// True when this source is currently considered the final segment
  /// for its playback.
  bool isTerminalSegment;

  bool _hasStarted = false;

  /// Whether the audio source has started playing.
  /// Once it starts, no more chunks can be added.
  bool get hasStarted => _hasStarted;

  /// Number of buffered bytes in this segment.
  int get bufferedBytes => _buffer.length;

  /// Add a chunk of audio data to the buffer.
  /// Returns false if the audio source has already started playing,
  /// true otherwise.
  bool addChunk(List<int> chunk) {
    if (_hasStarted) {
      return false;
    }

    _buffer.addAll(chunk);
    return true;
  }

  /// Marks this segment as no longer terminal for its playback.
  void markNonTerminal() {
    isTerminalSegment = false;
  }

  @override
  // other source did not work.
  // ignore: experimental_member_use
  Future<StreamAudioResponse> request([int? start, int? end]) async {
    _hasStarted = true;

    final List<List<int>> chunks;
    final String contentType;
    final int totalLength;

    if (audioSpec.format == TtsAudioFormat.pcm) {
      final header = _buildWavHeader(audioSpec.requirePcm, _buffer.length);
      chunks = [header, _buffer];
      contentType = 'audio/wav';
      totalLength = header.length + _buffer.length;
    } else {
      chunks = [_buffer];
      contentType = audioSpec.format.mimeType;
      totalLength = _buffer.length;
    }

    // other source did not work.
    // ignore: experimental_member_use
    return StreamAudioResponse(
      sourceLength: totalLength,
      contentLength: totalLength,
      offset: 0,
      rangeRequestsSupported: false,
      stream: Stream.fromIterable(chunks),
      contentType: contentType,
    );
  }

  /// Builds a 44-byte WAV header for the given [pcm] descriptor and [dataLengthBytes].
  static List<int> _buildWavHeader(PcmDescriptor pcm, int dataLengthBytes) {
    final int audioFormat = pcm.encoding == PcmEncoding.float ? 3 : 1;
    final int byteRate =
        pcm.sampleRateHz * pcm.channels * (pcm.bitsPerSample ~/ 8);
    final int blockAlign = pcm.channels * (pcm.bitsPerSample ~/ 8);
    final int riffChunkSize = 36 + dataLengthBytes;

    final header = ByteData(44);
    // RIFF chunk
    header.setUint8(0, 0x52); // R
    header.setUint8(1, 0x49); // I
    header.setUint8(2, 0x46); // F
    header.setUint8(3, 0x46); // F
    header.setUint32(4, riffChunkSize, Endian.little);
    header.setUint8(8, 0x57); // W
    header.setUint8(9, 0x41); // A
    header.setUint8(10, 0x56); // V
    header.setUint8(11, 0x45); // E
    // fmt sub-chunk
    header.setUint8(12, 0x66); // f
    header.setUint8(13, 0x6D); // m
    header.setUint8(14, 0x74); // t
    header.setUint8(15, 0x20); // (space)
    header.setUint32(16, 16, Endian.little); // sub-chunk size
    header.setUint16(20, audioFormat, Endian.little);
    header.setUint16(22, pcm.channels, Endian.little);
    header.setUint32(24, pcm.sampleRateHz, Endian.little);
    header.setUint32(28, byteRate, Endian.little);
    header.setUint16(32, blockAlign, Endian.little);
    header.setUint16(34, pcm.bitsPerSample, Endian.little);
    // data sub-chunk
    header.setUint8(36, 0x64); // d
    header.setUint8(37, 0x61); // a
    header.setUint8(38, 0x74); // t
    header.setUint8(39, 0x61); // a
    header.setUint32(40, dataLengthBytes, Endian.little);

    return header.buffer.asUint8List();
  }
}
