import 'dart:async';

import 'package:just_audio/just_audio.dart';
import 'package:just_audio_media_kit/just_audio_media_kit.dart';
import 'package:logging/logging.dart';
import 'package:meta/meta.dart';
import 'package:tts_flow_dart/tts_flow_dart.dart';
import 'package:tts_flow_flutter/src/just_audio/chunk_audio_source.dart';

final _logger = Logger('JustAudioPlayer');

final class _PlaybackSession {
  _PlaybackSession({
    required this.playbackId,
    required this.requestId,
    required this.audioSpec,
  });

  final String playbackId;
  final String requestId;
  final TtsAudioSpec audioSpec;

  ChunkAudioSource? tailSource;
  int totalBytes = 0;
  bool isFinalized = false;
  bool isStopped = false;
  Duration? playedDuration;
}

final class _SourceRange {
  const _SourceRange({required this.start, required this.endExclusive});

  final int start;
  final int endExclusive;
}

/// A [SpeakerBackend] implementation using the just_audio package.
class JustAudioBackend implements SpeakerBackend {
  /// constructor
  JustAudioBackend() : _player = AudioPlayer() {
    _processingStateSubscription = _player.processingStateStream.listen((
      state,
    ) {
      unawaited(_onProcessingStateChanged(state));
    });
  }

  /// Testing constructor that injects a preconfigured player.
  @visibleForTesting
  JustAudioBackend.testing({required AudioPlayer player}) : _player = player {
    _processingStateSubscription = _player.processingStateStream.listen((
      state,
    ) {
      unawaited(_onProcessingStateChanged(state));
    });
  }

  static bool _isInitialized = false;

  /// Ensure that just_audio media kit is initialized.
  /// It is recommended to call this in main.dart once
  static void ensureInitialized() {
    if (_isInitialized) {
      return;
    }

    JustAudioMediaKit.ensureInitialized();
    _isInitialized = true;
  }

  final AudioPlayer _player;
  final Map<String, _PlaybackSession> _sessions = <String, _PlaybackSession>{};
  final Set<String> _completedPlaybackIds = <String>{};
  final StreamController<SpeakerPlaybackCompletedEvent>
  _playbackCompletedController =
      StreamController<SpeakerPlaybackCompletedEvent>.broadcast();
  late final StreamSubscription<ProcessingState> _processingStateSubscription;

  @override
  Future<void> init() async {
    ensureInitialized();
  }

  @override
  Stream<SpeakerPlaybackCompletedEvent> get playbackCompletedEvents =>
      _playbackCompletedController.stream;

  /// Reset the player by stopping playback,
  /// seeking to the beginning, and clearing all audio sources.
  Future<void> reset() async {
    await _player.stop();
    await _player.seek(Duration.zero);
    await _player.clearAudioSources();
    _sessions.clear();
    _completedPlaybackIds.clear();
  }

  @override
  Future<void> appendAudio({
    required String playbackId,
    required List<int> bytes,
  }) async {
    if (bytes.isEmpty) {
      return;
    }

    final session = _requireSession(playbackId);
    if (session.isFinalized) {
      throw StateError('Playback is finalized: $playbackId');
    }
    if (session.isStopped) {
      throw StateError('Playback is stopped: $playbackId');
    }

    var target = session.tailSource;
    if (target == null || target.hasStarted) {
      target = await _createSegment(session);
    }

    if (!target.addChunk(bytes)) {
      target = await _createSegment(session);
      if (!target.addChunk(bytes)) {
        throw StateError('Unable to buffer bytes for playback: $playbackId');
      }
    }

    session.totalBytes += bytes.length;

    await _ensurePlaybackRunning();
  }

  @override
  Future<void> finalizeIngestion({required String playbackId}) async {
    final session = _requireSession(playbackId);
    if (session.isStopped) {
      throw StateError('Playback is stopped: $playbackId');
    }
    if (session.isFinalized) {
      return;
    }

    session.isFinalized = true;
    if (session.audioSpec.format == TtsAudioFormat.pcm) {
      session.playedDuration = _estimatePcmDuration(session);
    }
  }

  @override
  Future<void> dispose() async {
    await _processingStateSubscription.cancel();
    await _player.stop();
    await _player.clearAudioSources();
    _sessions.clear();
    _completedPlaybackIds.clear();
    await _player.dispose();
    await _playbackCompletedController.close();
  }

  @override
  Future<void> pausePlayback({required String playbackId}) async {
    _requireSession(playbackId);
    await _player.pause();
  }

  @override
  Future<void> resumePlayback({required String playbackId}) async {
    _requireSession(playbackId);
    await _ensurePlaybackRunning();
  }

  @override
  Future<String> startPlayback({
    required String requestId,
    required TtsAudioSpec audioSpec,
  }) async {
    var playbackId = 'playback-$requestId';
    var suffix = 1;
    while (_sessions.containsKey(playbackId)) {
      playbackId = 'playback-$requestId-$suffix';
      suffix++;
    }

    _sessions[playbackId] = _PlaybackSession(
      playbackId: playbackId,
      requestId: requestId,
      audioSpec: audioSpec,
    );
    _completedPlaybackIds.remove(playbackId);
    return playbackId;
  }

  @override
  Future<void> stopPlayback({
    required String playbackId,
    String? reason,
  }) async {
    final session = _requireSession(playbackId);
    // lint would want to remove the _requireSession()
    // ignore: cascade_invocations
    session.isStopped = true;

    final range = _findRangeForPlayback(playbackId);
    if (range == null) {
      _sessions.remove(playbackId);
      return;
    }

    final currentIndex = _player.currentIndex;
    await _player.removeAudioSourceRange(range.start, range.endExclusive);
    _sessions.remove(playbackId);
    _completedPlaybackIds.remove(playbackId);

    if (currentIndex != null &&
        currentIndex >= range.start &&
        currentIndex < range.endExclusive) {
      await _resumeAfterRemoval(range.start);
    }

    if (reason != null && reason.isNotEmpty) {
      _logger.fine('Stopped playback $playbackId, reason: $reason');
    }
  }

  @override
  Set<AudioCapability> get supportedCapabilities => {
    const Mp3Capability(),
    const OpusCapability(),
    const AacCapability(),
    PcmCapability.wav(),
  };

  _PlaybackSession _requireSession(String playbackId) {
    final session = _sessions[playbackId];
    if (session == null) {
      throw StateError('Unknown playbackId: $playbackId');
    }
    return session;
  }

  Future<ChunkAudioSource> _createSegment(_PlaybackSession session) async {
    final previousTail = session.tailSource;
    if (previousTail != null) {
      previousTail.markNonTerminal();
    }

    final source = ChunkAudioSource(
      audioSpec: session.audioSpec,
      playbackId: session.playbackId,
      requestId: session.requestId,
      isTerminalSegment: true,
    );

    session.tailSource = source;
    await _player.addAudioSource(source);
    _logger.fine('Added new segment for ${session.playbackId}');
    return source;
  }

  Future<void> _ensurePlaybackRunning() async {
    if (_player.audioSources.isEmpty) {
      return;
    }

    if (!_player.playing) {
      if (_player.processingState == ProcessingState.completed &&
          _player.currentIndex != null &&
          _player.currentIndex! < _player.audioSources.length - 1) {
        await _player.seekToNext();
      } else if (_player.currentIndex == null) {
        await _player.seek(Duration.zero, index: 0);
      }
      await _player.play();
      return;
    }

    if (_player.processingState == ProcessingState.completed &&
        _player.currentIndex != null &&
        _player.currentIndex! < _player.audioSources.length - 1) {
      await _player.seekToNext();
      await _player.play();
    }
  }

  _SourceRange? _findRangeForPlayback(String playbackId) {
    var seen = false;
    var gapStarted = false;
    int? start;
    var endExclusive = 0;

    for (var i = 0; i < _player.audioSources.length; i++) {
      final source = _player.audioSources[i];
      if (source is! ChunkAudioSource) {
        throw StateError(
          'Unexpected audio source type in playlist: ${source.runtimeType}',
        );
      }

      if (source.playbackId == playbackId) {
        if (gapStarted) {
          throw StateError('Playback segments must be contiguous: $playbackId');
        }
        seen = true;
        start ??= i;
        endExclusive = i + 1;
      } else if (seen) {
        gapStarted = true;
      }
    }

    if (start == null) {
      return null;
    }

    return _SourceRange(start: start, endExclusive: endExclusive);
  }

  Future<void> _resumeAfterRemoval(int removedStart) async {
    if (_player.audioSources.isEmpty) {
      await _player.stop();
      return;
    }

    final nextIndex = removedStart >= _player.audioSources.length
        ? _player.audioSources.length - 1
        : removedStart;
    await _player.stop();
    await _player.seek(Duration.zero, index: nextIndex);
    await _player.play();
  }

  Duration _estimatePcmDuration(_PlaybackSession session) {
    if (session.totalBytes == 0) {
      return Duration.zero;
    }

    final pcm = session.audioSpec.requirePcm;
    final bytesPerSample = (pcm.bitsPerSample / 8).ceil();
    final bytesPerFrame = bytesPerSample * pcm.channels;
    if (bytesPerFrame <= 0 || pcm.sampleRateHz <= 0) {
      return Duration.zero;
    }
    final frames = session.totalBytes / bytesPerFrame;
    final micros = (frames * Duration.microsecondsPerSecond / pcm.sampleRateHz)
        .round();
    return Duration(microseconds: micros);
  }

  Future<void> _onProcessingStateChanged(ProcessingState state) async {
    if (state != ProcessingState.completed) {
      return;
    }

    final index = _player.currentIndex;
    if (index == null || index < 0 || index >= _player.audioSources.length) {
      return;
    }

    final source = _player.audioSources[index];
    if (source is! ChunkAudioSource) {
      throw StateError(
        'Unexpected audio source type in playlist: ${source.runtimeType}',
      );
    }
    if (!source.isTerminalSegment) {
      return;
    }

    final playbackId = source.playbackId;
    if (!_completedPlaybackIds.add(playbackId)) {
      return;
    }

    final session = _sessions[playbackId];
    if (session == null) {
      return;
    }

    _playbackCompletedController.add(
      SpeakerPlaybackCompletedEvent(
        requestId: session.requestId,
        playbackId: playbackId,
        playedDuration: session.playedDuration,
      ),
    );

    final range = _findRangeForPlayback(playbackId);
    if (range == null) {
      _sessions.remove(playbackId);
      return;
    }

    final currentIndex = _player.currentIndex;
    await _player.removeAudioSourceRange(range.start, range.endExclusive);
    _sessions.remove(playbackId);

    if (currentIndex != null &&
        currentIndex >= range.start &&
        currentIndex < range.endExclusive) {
      await _resumeAfterRemoval(range.start);
    }
  }
}
