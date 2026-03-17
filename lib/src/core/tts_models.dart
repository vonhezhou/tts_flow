import 'dart:typed_data';

enum TtsAudioFormat { pcm16, mp3, wav, oggOpus, aac }

enum TtsRequestState { queued, running, completed, failed, stopped, canceled }

final class TtsVoice {
  const TtsVoice({required this.voiceId, this.locale, this.tags = const []});

  final String voiceId;
  final String? locale;
  final List<String> tags;
}

final class TtsOptions {
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

final class TtsRequest {
  const TtsRequest({
    required this.requestId,
    required this.text,
    this.voice,
    this.preferredFormat,
    this.options,
    this.metadata = const {},
  });

  final String requestId;
  final String text;
  final TtsVoice? voice;
  final TtsAudioFormat? preferredFormat;
  final TtsOptions? options;
  final Map<String, Object?> metadata;
}

final class TtsChunk {
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
