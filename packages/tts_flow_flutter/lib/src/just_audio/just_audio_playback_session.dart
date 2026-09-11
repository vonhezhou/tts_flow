part of 'just_audio_backend.dart';

/// Mutable state owned by one backend playback session.
///
/// The backend serializes all writes to this state through its player-operation
/// queue. This object deliberately has no player side effects.
final class _PlaybackSession {
  _PlaybackSession({
    required this.playbackId,
    required this.requestKey,
    required this.audioSpec,
  });

  final String playbackId;
  final String requestKey;
  final TtsAudioSpec audioSpec;

  ChunkAudioSource? tailSource;
  int totalBytes = 0;
  bool isFinalized = false;
  bool isStopped = false;
  bool isWaitingForNextSource = false;

  int nextIndex = 0;

  final completedSourceIndexes = <int>{};
  final sourceDurationMap = <int, Duration>{};

  void addOrUpdateSourceDuration(int index, Duration duration) {
    sourceDurationMap[index] = duration;
  }

  Duration calcDurationOffset(int index) {
    final previousDurations = sourceDurationMap.entries
        .where((entry) => entry.key < index)
        .map((entry) => entry.value);
    if (previousDurations.isEmpty) {
      return Duration.zero;
    }
    return previousDurations.reduce((value, element) => value + element);
  }

  Duration? calcTotalDuration() {
    if (sourceDurationMap.values.isEmpty) {
      return null;
    }
    return sourceDurationMap.values.reduce((value, element) => value + element);
  }
}

/// Contiguous source-list bounds occupied by one playback session.
final class _SourceRange {
  const _SourceRange({required this.start, required this.endExclusive});

  final int start;
  final int endExclusive;
}
