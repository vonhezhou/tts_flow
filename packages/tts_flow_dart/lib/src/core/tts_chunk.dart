import 'dart:typed_data';

import 'package:tts_flow_dart/src/core/audio_spec.dart';

abstract class TtsChunk {
  TtsChunk({
    required this.requestId,
    required this.sequenceNumber,
    required this.isLastChunk,
    required this.timestamp,
  });

  final String requestId;
  final int sequenceNumber;
  final bool isLastChunk;
  final DateTime timestamp;
}

class TtsAudioChunk extends TtsChunk {
  TtsAudioChunk({
    required super.requestId,
    required super.sequenceNumber,
    required super.isLastChunk,
    required super.timestamp,
    required this.bytes,
    required this.audioSpec,
  }) : assert(audioSpec.format == TtsAudioFormat.pcm || audioSpec.pcm == null);

  final Uint8List bytes;
  final TtsAudioSpec audioSpec;
}
