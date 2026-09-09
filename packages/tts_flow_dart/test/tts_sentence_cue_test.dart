import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:tts_flow_dart/tts_flow_dart.dart';

void main() {
  test(
    'cue emitted before audio bypasses the output before writing starts',
    () async {
      final flow = TtsFlow(
        engine: _CueFirstEngine(),
        defaultOutput: MemoryOutput(),
      );
      await flow.init();

      final chunks = await flow
          .speak('First sentence.', utteranceId: 'chapter-1')
          .chunks
          .toList();

      expect(chunks.first, isA<TtsSentenceCueChunk>());
      final cueChunk = chunks.first as TtsSentenceCueChunk;
      expect(cueChunk.cues.single.startOffset, 0);
      expect(cueChunk.cues.single.audioStart, Duration.zero);
      expect(chunks.last, isA<TtsAudioChunk>());

      await flow.dispose();
    },
  );
}

final class _CueFirstEngine with TtsEngineDefaults implements TtsEngine {
  @override
  String get engineId => 'cue-first';

  @override
  bool get supportsStreaming => true;

  @override
  int get maxInputByteSize => 0;

  @override
  Set<AudioCapability> get outAudioCapabilities => {const Mp3Capability()};

  @override
  Future<List<TtsVoice>> getAvailableVoices({String? locale}) async {
    return const [TtsVoice(voiceId: 'cue-first-default', isDefault: true)];
  }

  @override
  Future<TtsVoice> getDefaultVoice() async {
    return const TtsVoice(voiceId: 'cue-first-default', isDefault: true);
  }

  @override
  Future<TtsVoice> getDefaultVoiceForLocale(String locale) => getDefaultVoice();

  @override
  Future<void> init() async {}

  @override
  Future<void> dispose() async {}

  @override
  Stream<TtsChunk> synthesize(
    TtsRequest request,
    SynthesisControl control,
    TtsAudioSpec resolvedFormat,
  ) async* {
    yield TtsSentenceCueChunk(
      requestKey: request.requestKey,
      sequenceNumber: 0,
      isLastChunk: false,
      timestamp: DateTime.now().toUtc(),
      cues: const [
        TtsSentenceCue(
          startOffset: 0,
          endOffset: 15,
          audioStart: Duration.zero,
        ),
      ],
    );
    yield TtsAudioChunk(
      requestKey: request.requestKey,
      sequenceNumber: 1,
      isLastChunk: true,
      timestamp: DateTime.now().toUtc(),
      bytes: Uint8List.fromList([1, 2, 3]),
      audioSpec: resolvedFormat,
    );
  }
}
