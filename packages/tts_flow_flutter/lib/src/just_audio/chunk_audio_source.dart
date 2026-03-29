import 'dart:async';

import 'package:just_audio/just_audio.dart';
import 'package:tts_flow_dart/tts_flow_dart.dart';

/// other source did not work.
// ignore: experimental_member_use
class ChunkAudioSource extends StreamAudioSource {
  ///
  ChunkAudioSource({
    required this.format,
    required this.playbackId,
    required this.requestId,
    required this.isTerminalSegment,
  });

  final List<int> _buffer = [];

  /// The audio format of this segment.
  final TtsAudioFormat format;

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

    // other source did not work.
    // ignore: experimental_member_use
    return StreamAudioResponse(
      sourceLength: _buffer.length,
      contentLength: _buffer.length,
      offset: 0,
      rangeRequestsSupported: false,
      stream: Stream.fromIterable([_buffer]),
      contentType: format.mimeType,
    );
  }
}
