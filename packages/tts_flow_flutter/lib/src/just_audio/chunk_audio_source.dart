import 'dart:async';

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
    required this.index,
    required this.isTerminalSegment,
  });

  final List<int> _buffer = [];

  /// The audio spec (format + optional PCM descriptor) for this segment.
  final TtsAudioSpec audioSpec;

  /// Convenience accessor for the audio format.
  TtsAudioFormat get format => audioSpec.format;

  /// The playback identifier for the session this segment belongs to.
  final String playbackId;

  /// the index in the playback stream.
  final int index;

  /// The request identifier for the TTS request this segment belongs to.
  final String requestId;

  /// The previous duration of this session.
  Duration playbackOffset = Duration.zero;

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
      final header = WavHeader.fromPcmDescriptor(
        audioSpec.requirePcm,
        dataLengthBytes: _buffer.length,
      ).toBytes();
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
}
