import 'dart:typed_data';

import 'package:tts_flow_dart/src/base/audio_spec.dart';

enum TtsRequestState { queued, running, completed, failed, stopped, canceled }

/// A class representing a TTS voice with its associated properties.
class TtsVoice {
  const TtsVoice({
    required this.voiceId,
    this.locale,
    this.displayName,
    this.isDefault = false,
  });

  final String voiceId;
  final String? locale;
  final String? displayName;
  final bool isDefault;
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

  TtsOptions copyWith({
    double? speed,
    double? pitch,
    double? volume,
    int? sampleRateHz,
    Duration? timeout,
  }) {
    return TtsOptions(
      speed: speed ?? this.speed,
      pitch: pitch ?? this.pitch,
      volume: volume ?? this.volume,
      sampleRateHz: sampleRateHz ?? this.sampleRateHz,
      timeout: timeout ?? this.timeout,
    );
  }
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
    required this.audioSpec,
    required this.isLastChunk,
    required this.timestamp,
  });

  final String requestId;
  final int sequenceNumber;
  final Uint8List bytes;
  final TtsAudioSpec audioSpec;
  final bool isLastChunk;
  final DateTime timestamp;
}
