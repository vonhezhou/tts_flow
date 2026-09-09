import 'dart:math' as math;

import 'package:tts_flow_dart/tts_flow_dart.dart';
import 'package:tts_flow_flutter_example/reader/sentence_splitter.dart';

/// A deterministic demo engine that models a provider with sentence timings.
///
/// Real provider adapters should replace the estimated cue construction with
/// server-supplied boundaries. The emitted sine audio follows the same
/// word-duration rule used to calculate these demo cue offsets.
final class DemoSentenceCueEngine with TtsEngineDefaults implements TtsEngine {
  DemoSentenceCueEngine()
    : _delegate = SineTtsEngine(
        engineId: 'reader-demo-sine',
        supportsStreaming: true,
        chunkCount: 4,
        chunkDelay: const Duration(milliseconds: 120),
      );

  final SineTtsEngine _delegate;

  @override
  String get engineId => _delegate.engineId;

  @override
  bool get supportsStreaming => _delegate.supportsStreaming;

  @override
  int get maxInputCharacterCount => _delegate.maxInputCharacterCount;

  @override
  Set<AudioCapability> get outAudioCapabilities =>
      _delegate.outAudioCapabilities;

  @override
  Future<List<TtsVoice>> getAvailableVoices({String? locale}) =>
      _delegate.getAvailableVoices(locale: locale);

  @override
  Future<TtsVoice> getDefaultVoice() => _delegate.getDefaultVoice();

  @override
  Future<TtsVoice> getDefaultVoiceForLocale(String locale) =>
      _delegate.getDefaultVoiceForLocale(locale);

  @override
  Future<void> init() => _delegate.init();

  @override
  Future<void> dispose() => _delegate.dispose();

  @override
  Stream<TtsChunk> synthesize(
    TtsRequest request,
    SynthesisControl control,
    TtsAudioSpec resolvedFormat,
  ) async* {
    final cues = <TtsSentenceCue>[];
    var offset = Duration.zero;
    for (final sentence in splitSentences(request.text)) {
      final sentenceText = request.text.substring(
        sentence.startOffset,
        sentence.endOffset,
      );
      cues.add(
        TtsSentenceCue(
          startOffset: sentence.startOffset,
          endOffset: sentence.endOffset,
          audioStart: offset,
        ),
      );
      offset += _durationFor(sentenceText);
    }
    if (cues.isNotEmpty) {
      yield TtsSentenceCueChunk(
        requestKey: request.requestKey,
        sequenceNumber: 0,
        isLastChunk: false,
        timestamp: DateTime.now().toUtc(),
        cues: cues,
      );
    }

    await for (final chunk in _delegate.synthesize(
      request,
      control,
      resolvedFormat,
    )) {
      if (chunk is TtsAudioChunk) {
        yield TtsAudioChunk(
          requestKey: chunk.requestKey,
          sequenceNumber: chunk.sequenceNumber + 1,
          isLastChunk: chunk.isLastChunk,
          timestamp: chunk.timestamp,
          bytes: chunk.bytes,
          audioSpec: chunk.audioSpec,
        );
      }
    }
  }

  Duration _durationFor(String text) {
    final wordCount = text
        .trim()
        .split(RegExp(r'\s+'))
        .where((word) => word.isNotEmpty)
        .length;
    final seconds = math.max(0.1, wordCount * 0.3);
    return Duration(milliseconds: (seconds * 1000).round());
  }
}
