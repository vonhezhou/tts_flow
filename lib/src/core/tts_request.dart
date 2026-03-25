import 'package:tts_flow_dart/src/core/audio_spec.dart';
import 'package:tts_flow_dart/src/core/tts_output.dart';
import 'package:tts_flow_dart/src/core/tts_voice.dart';

enum TtsRequestState { queued, running, completed, failed, stopped, canceled }

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
    this.output,
  });

  final String requestId;
  final String text;
  final TtsVoice? voice;
  final TtsAudioFormat? preferredFormat;
  final TtsOptions? options;
  final Map<String, Object> params;
  final TtsOutput? output;
}
