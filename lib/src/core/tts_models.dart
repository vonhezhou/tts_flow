import 'dart:typed_data';

enum TtsAudioFormat { pcm, mp3, wav, opus, aac }

enum TtsRequestState { queued, running, completed, failed, stopped, canceled }

/// A class representing a TTS voice with its associated properties.
class TtsVoice {
  const TtsVoice({required this.voiceId});

  final String voiceId;
}

class TtsOptions {
  const TtsOptions({
    this.speed,
    this.pitch,
    this.volume,
    this.sampleRateHz,
    this.timeout,
  });

  final double? speed;
  final double? pitch;
  final double? volume;
  final int? sampleRateHz;
  final Duration? timeout;
}

class TtsRequest {
  const TtsRequest({
    required this.requestId,
    required this.text,
    this.voice,
    this.preferredFormat,
    this.options,
    this.params = const {},
  });

  final String requestId;
  final String text;
  final TtsVoice? voice;
  final TtsAudioFormat? preferredFormat;
  final TtsOptions? options;
  final Map<String, Object> params;
}

class TtsChunk {
  const TtsChunk({
    required this.requestId,
    required this.sequenceNumber,
    required this.bytes,
    required this.format,
    required this.isLastChunk,
    required this.timestamp,
  });

  final String requestId;
  final int sequenceNumber;
  final Uint8List bytes;
  final TtsAudioFormat format;
  final bool isLastChunk;
  final DateTime timestamp;
}
