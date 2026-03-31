import 'dart:typed_data';

import 'package:tts_flow_dart/src/core/audio_spec.dart';

class TtsChunk {
  TtsChunk({
    required this.requestId,
    required this.sequenceNumber,
    required this.bytes,
    required this.audioSpec,
    required this.isLastChunk,
    required this.timestamp,
  }) : assert(audioSpec.format != TtsAudioFormat.pcm || audioSpec.pcm != null);

  final String requestId;
  final int sequenceNumber;
  final Uint8List bytes;
  final TtsAudioSpec audioSpec;
  final bool isLastChunk;
  final DateTime timestamp;
}
