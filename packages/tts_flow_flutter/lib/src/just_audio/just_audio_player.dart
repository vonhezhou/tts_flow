import 'dart:async';

import 'package:just_audio/just_audio.dart';
import 'package:logging/logging.dart';
import 'package:tts_flow_dart/tts_flow_dart.dart';

final _logger = Logger('JustAudioPlayer');

/// A [SpeakerBackend] implementation using the just_audio package.
class JustAudioBackend implements SpeakerBackend {
  /// constructor
  JustAudioBackend({required this.player});

  /// The just_audio player instance.
  AudioPlayer player;

  ChunkAudioSource? _pendingSource;

  /// Reset the player by stopping playback,
  /// seeking to the beginning, and clearing all audio sources.
  Future<void> reset() async {
    await player.stop();
    await player.seek(Duration.zero);
    _pendingSource = null;
    await player.clearAudioSources();
  }

  Future<void> bufferAudio(List<int> buffer, TtsAudioFormat format) async {
    if (_pendingSource == null) {
      _pendingSource = ChunkAudioSource(format: format);
      await player.addAudioSource(_pendingSource!);
      _logger.fine('create new audio source:${buffer.length}');
    } else if (_pendingSource!.hasStarted || _pendingSource!.format != format) {
      _pendingSource = ChunkAudioSource(format: format);
      await player.addAudioSource(_pendingSource!);
      _logger.fine('add new audio source:${buffer.length}');
    } else {
      _logger.fine(
        'add chunk to existing audio source:${buffer.length}',
      );
    }
    _pendingSource!.addChunk(buffer);
  }

  Future<void> play(List<int> buffer, TtsAudioFormat format) async {
    await bufferAudio(buffer, format);

    if (!player.playing) {
      if (player.processingState == ProcessingState.completed &&
          player.currentIndex != null &&
          player.currentIndex! < (player.audioSources.length) - 1) {
        await player.seekToNext();
      }
      await player.play();
    } else if (player.processingState == ProcessingState.completed &&
        player.currentIndex != null &&
        player.currentIndex! < (player.audioSources.length) - 1) {
      await player.seekToNext();
      await player.play();
    }

    // Remove previous audio sources if any
    final curIndex = player.currentIndex ?? 0;
    if (curIndex > 0) {
      await player.removeAudioSourceRange(0, curIndex);
    }
  }

  @override
  Future<void> appendAudio({
    required String playbackId,
    required List<int> bytes,
  }) {
    // TODO: implement appendAudio
    throw UnimplementedError();
  }

  @override
  Future<Duration> completePlayback({required String playbackId}) {
    // TODO: implement completePlayback
    throw UnimplementedError();
  }

  @override
  Future<void> dispose() {
    // TODO: implement dispose
    throw UnimplementedError();
  }

  @override
  Future<void> pausePlayback({required String playbackId}) {
    // TODO: implement pausePlayback
    throw UnimplementedError();
  }

  @override
  Future<void> resumePlayback({required String playbackId}) {
    // TODO: implement resumePlayback
    throw UnimplementedError();
  }

  @override
  Future<String> startPlayback({
    required String requestId,
    required TtsAudioSpec audioSpec,
  }) {
    // TODO: implement startPlayback
    throw UnimplementedError();
  }

  @override
  Future<void> stopPlayback({required String playbackId, String? reason}) {
    // TODO: implement stopPlayback
    throw UnimplementedError();
  }

  @override
  // TODO: implement supportedCapabilities
  Set<AudioCapability> get supportedCapabilities => throw UnimplementedError();
}

/// other source did not work.
// ignore: experimental_member_use
class ChunkAudioSource extends StreamAudioSource {
  ///
  ChunkAudioSource({
    required this.format,
  });

  final List<int> _buffer = [];
  final TtsAudioFormat format;

  bool _hasStarted = false;

  /// Whether the audio source has started playing.
  /// Once it starts, no more chunks can be added.
  bool get hasStarted => _hasStarted;

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
