import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:tts_flow_dart/tts_flow_dart.dart';
import 'package:tts_flow_flutter_example/reader/reading_request.dart';

/// The text range currently rendered as active in the reader UI.
final class ReadingHighlight {
  const ReadingHighlight({
    required this.startOffset,
    required this.endOffset,
    required this.requestKey,
    required this.isEstimated,
  });

  final int startOffset;
  final int endOffset;
  final String requestKey;

  /// True when the provider gave no sentence timing and the full request is
  /// highlighted as the documented fallback.
  final bool isEstimated;
}

/// Connects request-level TTS timing to offsets in a book passage.
final class ReadingSession {
  ReadingSession({
    required TtsFlow flow,
    required PlaybackTimelineReporter? timelineReporter,
  }) : _flow = flow,
       _timelineReporter = timelineReporter {
    _timelineSubscription = _timelineReporter?.playbackPositionEvents.listen(
      _onPlaybackPosition,
    );
    if (_timelineReporter == null) {
      _requestSubscription = _flow.requestEvents.listen(_onRequestEvent);
    }
  }

  final TtsFlow _flow;
  final PlaybackTimelineReporter? _timelineReporter;
  final ValueNotifier<ReadingHighlight?> highlight =
      ValueNotifier<ReadingHighlight?>(null);
  final Map<String, ReadingRequest> _requests = <String, ReadingRequest>{};
  final Map<String, List<TtsSentenceCue>> _cues =
      <String, List<TtsSentenceCue>>{};
  final Map<String, Duration> _positions = <String, Duration>{};
  final List<TtsRequestHandle> _requestHandles = <TtsRequestHandle>[];
  final List<StreamSubscription<TtsChunk>> _synthesisSubscriptions =
      <StreamSubscription<TtsChunk>>[];
  StreamSubscription<TtsPlaybackPositionEvent>? _timelineSubscription;
  StreamSubscription<TtsRequestEvent>? _requestSubscription;
  var _sessionNumber = 0;

  bool get supportsPreciseSentenceTiming => _timelineReporter != null;

  Future<void> start(String text) async {
    await stop();
    _sessionNumber++;
    final planned = planReadingRequests(
      text: text,
      utteranceIdPrefix: 'reader-$_sessionNumber',
    );
    for (final request in planned) {
      final handle = _flow.speak(
        request.text,
        utteranceId: request.utteranceId,
      );
      _requestHandles.add(handle);
      _requests[handle.requestKey] = request;
      final subscription = handle.chunks.listen((chunk) {
        if (chunk is TtsSentenceCueChunk) {
          _storeCues(chunk);
        }
      });
      _synthesisSubscriptions.add(subscription);
    }
  }

  Future<void> stop() async {
    for (final handle in _requestHandles) {
      await handle.stopSynthesis();
    }
    await _flow.clearQueue();
    for (final handle in _requestHandles) {
      if (handle.hasActivePlayback) {
        await handle.stopPlayback();
      }
    }
    for (final subscription in _synthesisSubscriptions) {
      await subscription.cancel();
    }
    _synthesisSubscriptions.clear();
    _requestHandles.clear();
    _requests.clear();
    _cues.clear();
    _positions.clear();
    highlight.value = null;
  }

  void _storeCues(TtsSentenceCueChunk chunk) {
    final cues = _cues.putIfAbsent(chunk.requestKey, () => <TtsSentenceCue>[]);
    cues
      ..addAll(chunk.cues)
      ..sort((a, b) => a.audioStart.compareTo(b.audioStart));
    final currentPosition = _positions[chunk.requestKey];
    if (currentPosition != null) {
      _updateHighlight(chunk.requestKey, currentPosition);
    }
  }

  void _onPlaybackPosition(TtsPlaybackPositionEvent event) {
    if (!_requests.containsKey(event.requestKey)) {
      return;
    }
    _positions[event.requestKey] = event.position;
    _updateHighlight(event.requestKey, event.position);
  }

  void _onRequestEvent(TtsRequestEvent event) {
    if (event.type != TtsRequestEventType.requestStarted) {
      return;
    }
    final request = _requests[event.requestKey];
    if (request == null) {
      return;
    }
    _setHighlight(
      ReadingHighlight(
        requestKey: event.requestKey,
        startOffset: request.documentStartOffset,
        endOffset: request.documentStartOffset + request.text.length,
        isEstimated: true,
      ),
    );
  }

  void _updateHighlight(String requestKey, Duration position) {
    final request = _requests[requestKey];
    if (request == null) {
      return;
    }
    final cues = _cues[requestKey];
    if (cues == null || cues.isEmpty) {
      _setHighlight(
        ReadingHighlight(
          requestKey: requestKey,
          startOffset: request.documentStartOffset,
          endOffset: request.documentStartOffset + request.text.length,
          isEstimated: true,
        ),
      );
      return;
    }

    TtsSentenceCue? selected;
    for (final cue in cues) {
      if (cue.audioStart > position) {
        break;
      }
      selected = cue;
    }
    if (selected == null) {
      return;
    }
    _setHighlight(
      ReadingHighlight(
        requestKey: requestKey,
        startOffset: request.documentStartOffset + selected.startOffset,
        endOffset: request.documentStartOffset + selected.endOffset,
        isEstimated: false,
      ),
    );
  }

  void _setHighlight(ReadingHighlight next) {
    final current = highlight.value;
    if (current?.requestKey == next.requestKey &&
        current?.startOffset == next.startOffset &&
        current?.endOffset == next.endOffset &&
        current?.isEstimated == next.isEstimated) {
      return;
    }
    highlight.value = next;
  }

  Future<void> dispose() async {
    await stop();
    await _timelineSubscription?.cancel();
    await _requestSubscription?.cancel();
    highlight.dispose();
  }
}
