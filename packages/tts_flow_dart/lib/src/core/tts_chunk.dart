import 'dart:typed_data';

import 'package:tts_flow_dart/src/core/audio_spec.dart';
import 'package:tts_flow_dart/src/core/tts_sentence_cue.dart';

abstract class TtsChunk {
  TtsChunk({
    required this.requestKey,
    required this.sequenceNumber,
    required this.isLastChunk,
    required this.timestamp,
  });

  final String requestKey;
  final int sequenceNumber;
  final bool isLastChunk;
  final DateTime timestamp;
}

class TtsAudioChunk extends TtsChunk {
  TtsAudioChunk({
    required super.requestKey,
    required super.sequenceNumber,
    required super.isLastChunk,
    required super.timestamp,
    required this.bytes,
    required this.audioSpec,
  }) : assert(audioSpec.format == TtsAudioFormat.pcm || audioSpec.pcm == null);

  final Uint8List bytes;
  final TtsAudioSpec audioSpec;
}

/// Semantic timing metadata emitted by a TTS provider.
///
/// This chunk contains no audio bytes. A provider emits it only when it can
/// reliably align sentences to the request audio timeline. Consumers should
/// cache its cues and match them with physical playback position events.
class TtsSentenceCueChunk extends TtsChunk {
  TtsSentenceCueChunk({
    required super.requestKey,
    required super.sequenceNumber,
    required super.isLastChunk,
    required super.timestamp,
    required List<TtsSentenceCue> cues,
  }) : cues = List.unmodifiable(cues) {
    if (this.cues.isEmpty) {
      throw ArgumentError.value(cues, 'cues', 'Must not be empty.');
    }
  }

  final List<TtsSentenceCue> cues;
}
