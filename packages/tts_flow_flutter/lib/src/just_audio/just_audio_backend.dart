import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';
import 'package:just_audio_media_kit/just_audio_media_kit.dart';
import 'package:logging/logging.dart';
import 'package:tts_flow_dart/tts_flow_dart.dart';
import 'package:tts_flow_flutter/src/just_audio/chunk_audio_source.dart';

part 'just_audio_playback_session.dart';
part 'just_audio_source_list_operations.dart';

final _logger = Logger('JustAudioPlayer');

/// A platform playback failure associated with one TTS playback session.
final class JustAudioPlaybackErrorEvent {
  /// Creates a playback error event.
  const JustAudioPlaybackErrorEvent({
    required this.playbackId,
    required this.requestKey,
    required this.error,
  });

  /// The backend-owned playback session identifier.
  final String playbackId;

  /// The TTS request that owns the failed playback session.
  final String requestKey;

  /// The platform error emitted by just_audio.
  final PlayerException error;
}

/// A non-finalized playback session ran out of queued source data.
///
/// This is a diagnostic event for measuring controlled network-jitter cases.
/// It does not mean the session failed: a later chunk can create a new source
/// and resume playback.
final class JustAudioPlaybackWaitingEvent {
  /// Creates a waiting event for a source-list playback underflow.
  const JustAudioPlaybackWaitingEvent({
    required this.playbackId,
    required this.requestKey,
    required this.sourceIndex,
    required this.timestamp,
  });

  /// The backend-owned playback session identifier.
  final String playbackId;

  /// The TTS request that owns this playback session.
  final String requestKey;

  /// Index of the source that exhausted the currently queued playlist.
  final int sourceIndex;

  /// Time at which the backend observed the source-list underflow.
  final DateTime timestamp;
}

/// A source has started being read by the native player.
///
/// This is emitted from [ChunkAudioSource.request], which is the precise point
/// after which that source becomes immutable.
final class JustAudioPlaybackSourceStartedEvent {
  /// Creates a source-start event.
  const JustAudioPlaybackSourceStartedEvent({
    required this.playbackId,
    required this.requestKey,
    required this.sourceIndex,
    required this.timestamp,
  });

  /// The backend-owned playback session identifier.
  final String playbackId;

  /// The TTS request that owns this playback session.
  final String requestKey;

  /// Index of the source the native player began reading.
  final int sourceIndex;

  /// Time at which the source became immutable.
  final DateTime timestamp;
}

/// A [SpeakerBackend] implementation using the just_audio package.
class JustAudioBackend
    implements
        SpeakerBackend,
        SpeakerPlaybackFailureAwareBackend,
        PlaybackTimelineReporter {
  /// constructor
  JustAudioBackend() : _player = _createPlayer() {
    _processingStateSubscription = _player.processingStateStream.listen((
      state,
    ) {
      unawaited(
        _enqueuePlayerOperation(() => _onProcessingStateChanged(state)),
      );
    });

    _durationSubscription = _player.durationStream.listen(_onDurationChanged);
    _posSubscription = _player.positionStream.listen(_onPosChanged);
    _errorSubscription = _player.errorStream.listen((error) {
      unawaited(_enqueuePlayerOperation(() => _onPlayerError(error)));
    });
  }

  /// Testing constructor that injects a preconfigured player.
  @visibleForTesting
  JustAudioBackend.testing({required AudioPlayer player}) : _player = player {
    _processingStateSubscription = _player.processingStateStream.listen((
      state,
    ) {
      unawaited(
        _enqueuePlayerOperation(() => _onProcessingStateChanged(state)),
      );
    });
    _durationSubscription = _player.durationStream.listen(_onDurationChanged);
    _posSubscription = _player.positionStream.listen(_onPosChanged);
    _errorSubscription = _player.errorStream.listen((error) {
      unawaited(_enqueuePlayerOperation(() => _onPlayerError(error)));
    });
  }

  static bool _isInitialized = false;

  static AudioPlayer _createPlayer() {
    ensureInitialized();
    return AudioPlayer();
  }

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
  final StreamController<SpeakerPlaybackFailedEvent> _playbackFailedController =
      StreamController<SpeakerPlaybackFailedEvent>.broadcast();
  late final StreamSubscription<ProcessingState> _processingStateSubscription;

  late final StreamSubscription<Duration?> _durationSubscription;

  final StreamController<TtsPlaybackPositionEvent> _playbackPositionController =
      StreamController<TtsPlaybackPositionEvent>.broadcast();
  late final StreamSubscription<Duration?> _posSubscription;

  final StreamController<JustAudioPlaybackErrorEvent> _playbackErrorController =
      StreamController<JustAudioPlaybackErrorEvent>.broadcast();
  final StreamController<JustAudioPlaybackWaitingEvent>
  _playbackWaitingController =
      StreamController<JustAudioPlaybackWaitingEvent>.broadcast();
  final StreamController<JustAudioPlaybackSourceStartedEvent>
  _playbackSourceStartedController =
      StreamController<JustAudioPlaybackSourceStartedEvent>.broadcast();
  late final StreamSubscription<PlayerException> _errorSubscription;

  Future<void> _playerOperationTail = Future<void>.value();
  var _disposeRequested = false;

  @override
  Stream<TtsPlaybackPositionEvent> get playbackPositionEvents =>
      _playbackPositionController.stream;

  /// Platform playback errors associated with a TTS playback session.
  Stream<JustAudioPlaybackErrorEvent> get playbackErrorStream =>
      _playbackErrorController.stream;

  /// Emits when an unfinished session exhausts its currently queued sources.
  ///
  /// Use this for diagnostics and integration-test telemetry; it is not a
  /// playback failure and a later chunk may resume the session.
  Stream<JustAudioPlaybackWaitingEvent> get playbackWaitingStream =>
      _playbackWaitingController.stream;

  /// Emits when a platform first requests a source's immutable byte snapshot.
  Stream<JustAudioPlaybackSourceStartedEvent> get playbackSourceStartedStream =>
      _playbackSourceStartedController.stream;

  /// The underlying just_audio player instance.
  AudioPlayer get player => _player;

  @override
  Future<void> init() async {
    ensureInitialized();
  }

  @override
  Stream<SpeakerPlaybackCompletedEvent> get playbackCompletedEvents =>
      _playbackCompletedController.stream;

  @override
  Stream<SpeakerPlaybackFailedEvent> get playbackFailedEvents =>
      _playbackFailedController.stream;

  /// Reset the player by stopping playback,
  /// seeking to the beginning, and clearing all audio sources.
  Future<void> reset() => _enqueuePlayerOperation(() async {
    await _player.stop();
    await _player.seek(Duration.zero);
    await _player.clearAudioSources();
    _sessions.clear();
    _completedPlaybackIds.clear();
  });

  @override
  Future<void> appendChunk({
    required String playbackId,
    required TtsChunk chunk,
  }) => _enqueuePlayerOperation(
    () => _appendChunk(playbackId: playbackId, chunk: chunk),
  );

  Future<void> _appendChunk({
    required String playbackId,
    required TtsChunk chunk,
  }) async {
    if (chunk is! TtsAudioChunk) {
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

    if (!target.addChunk(chunk.bytes)) {
      target = await _createSegment(session);
      if (!target.addChunk(chunk.bytes)) {
        throw StateError('Unable to buffer bytes for playback: $playbackId');
      }
    }

    session
      ..totalBytes += chunk.bytes.length
      ..isWaitingForNextSource = false;

    await _ensurePlaybackRunning();
  }

  @override
  Future<void> finalizePlayback({required String playbackId}) =>
      _enqueuePlayerOperation(() => _finalizePlayback(playbackId));

  Future<void> _finalizePlayback(String playbackId) async {
    final session = _requireSession(playbackId);
    if (session.isStopped) {
      throw StateError('Playback is stopped: $playbackId');
    }
    if (session.isFinalized) {
      return;
    }

    session.isFinalized = true;
    final tail = session.tailSource;
    tail?.isTerminalSegment = true;
    if (tail == null || session.completedSourceIndexes.contains(tail.index)) {
      await _completePlayback(session);
    }
  }

  @override
  Future<void> dispose() async {
    if (_disposeRequested) {
      return;
    }
    _disposeRequested = true;
    await _processingStateSubscription.cancel();
    await _durationSubscription.cancel();
    await _posSubscription.cancel();
    await _errorSubscription.cancel();
    await _enqueuePlayerOperation(() async {
      await _player.stop();
      await _player.clearAudioSources();
      _sessions.clear();
      _completedPlaybackIds.clear();
      await _player.dispose();
    });
    await _playbackPositionController.close();
    await _playbackCompletedController.close();
    await _playbackFailedController.close();
    await _playbackErrorController.close();
    await _playbackWaitingController.close();
    await _playbackSourceStartedController.close();
  }

  @override
  Future<void> pausePlayback({required String playbackId}) =>
      _enqueuePlayerOperation(() async {
        _requireSession(playbackId);
        await _player.pause();
      });

  @override
  Future<void> resumePlayback({required String playbackId}) =>
      _enqueuePlayerOperation(() async {
        _requireSession(playbackId);
        await _ensurePlaybackRunning();
      });

  @override
  Future<String> startPlayback({
    required String requestKey,
    required TtsAudioSpec audioSpec,
  }) => _enqueuePlayerOperation(() async {
    var playbackId = requestKey;
    var suffix = 1;
    while (_sessions.containsKey(playbackId)) {
      playbackId = '$requestKey-$suffix';
      suffix++;
    }

    _sessions[playbackId] = _PlaybackSession(
      playbackId: playbackId,
      requestKey: requestKey,
      audioSpec: audioSpec,
    );
    _completedPlaybackIds.remove(playbackId);
    return playbackId;
  });

  @override
  Future<void> stopPlayback({
    required String playbackId,
    String? reason,
  }) => _enqueuePlayerOperation(
    () => _stopPlayback(playbackId: playbackId, reason: reason),
  );

  Future<void> _stopPlayback({
    required String playbackId,
    String? reason,
  }) async {
    final session = _sessions[playbackId];
    if (session == null) {
      return;
    }
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
    final playbackId = source.playbackId;
    final session = _sessions[playbackId];
    if (session == null) {
      return;
    }

    session.completedSourceIndexes.add(source.index);
    if (!session.isFinalized || !identical(source, session.tailSource)) {
      if (!session.isFinalized && !session.isWaitingForNextSource) {
        _playbackWaitingController.add(
          JustAudioPlaybackWaitingEvent(
            playbackId: session.playbackId,
            requestKey: session.requestKey,
            sourceIndex: source.index,
            timestamp: DateTime.now().toUtc(),
          ),
        );
      }
      session.isWaitingForNextSource = !session.isFinalized;
      return;
    }

    await _completePlayback(session);
  }

  Future<void> _completePlayback(_PlaybackSession session) async {
    if (!_completedPlaybackIds.add(session.playbackId)) {
      return;
    }

    _playbackCompletedController.add(
      SpeakerPlaybackCompletedEvent(
        requestKey: session.requestKey,
        playbackId: session.playbackId,
        playedDuration: session.calcTotalDuration(),
      ),
    );

    final range = _findRangeForPlayback(session.playbackId);
    if (range == null) {
      _sessions.remove(session.playbackId);
      return;
    }

    final currentIndex = _player.currentIndex;
    await _player.removeAudioSourceRange(range.start, range.endExclusive);
    _sessions.remove(session.playbackId);

    if (currentIndex != null &&
        currentIndex >= range.start &&
        currentIndex < range.endExclusive) {
      await _resumeAfterRemoval(range.start);
    }
  }

  Future<void> _onPlayerError(PlayerException error) async {
    final sourceIndex = error.index ?? _player.currentIndex;
    if (sourceIndex == null ||
        sourceIndex < 0 ||
        sourceIndex >= _player.audioSources.length) {
      _logger.warning('Unattributed just_audio playback error: $error');
      return;
    }

    final source = _player.audioSources[sourceIndex];
    if (source is! ChunkAudioSource) {
      _logger.warning('Playback error on unexpected source type: $error');
      return;
    }

    final session = _sessions[source.playbackId];
    if (session == null) {
      return;
    }

    _playbackErrorController.add(
      JustAudioPlaybackErrorEvent(
        playbackId: session.playbackId,
        requestKey: session.requestKey,
        error: error,
      ),
    );
    _playbackFailedController.add(
      SpeakerPlaybackFailedEvent(
        requestKey: session.requestKey,
        playbackId: session.playbackId,
        error: TtsError(
          code: TtsErrorCode.outputPlaybackFailed,
          message: 'just_audio playback failed: ${error.message ?? error.code}',
          requestKey: session.requestKey,
          cause: error,
        ),
      ),
    );
    await _stopPlayback(
      playbackId: session.playbackId,
      reason: 'just_audio error ${error.code}: ${error.message ?? ''}',
    );
  }

  Future<T> _enqueuePlayerOperation<T>(Future<T> Function() operation) {
    final result = _playerOperationTail.then((_) => operation());
    _playerOperationTail = result.then<void>(
      (_) {},
      onError: (_, _) {},
    );
    return result;
  }

  AudioSource? _currentSource() {
    final index = _player.currentIndex;
    if (index == null || index < 0 || index >= _player.audioSources.length) {
      return null;
    }

    return _player.audioSources.elementAtOrNull(index);
  }

  void _onDurationChanged(Duration? duration) {
    if (duration == null) {
      return;
    }

    final curSource = _currentSource();
    if (curSource == null) {
      return;
    }

    if (curSource is! ChunkAudioSource) {
      return;
    }

    final session = _sessions[curSource.playbackId];
    if (session == null) {
      return;
    }

    session.addOrUpdateSourceDuration(curSource.index, duration);
    final prevDuration = session.calcDurationOffset(curSource.index);
    curSource.playbackOffset = prevDuration;

    _logger.fine(
      'onDuration: '
      '${curSource.requestKey},${curSource.index} '
      '$duration, ${curSource.playbackOffset}',
    );
  }

  void _onPosChanged(Duration pos) {
    final curSource = _currentSource();
    if (curSource == null || curSource is! ChunkAudioSource) {
      return;
    }

    final session = _sessions[curSource.playbackId];
    if (session == null) {
      return;
    }

    // try to fix playbackOffset
    if (curSource.index != 0 && curSource.playbackOffset == Duration.zero) {
      curSource.playbackOffset = session.calcDurationOffset(
        curSource.index,
      );
    }

    final newPos = curSource.playbackOffset + pos;
    _playbackPositionController.add(
      TtsPlaybackPositionEvent(
        playbackId: curSource.playbackId,
        requestKey: curSource.requestKey,
        position: newPos,
      ),
    );
  }
}
