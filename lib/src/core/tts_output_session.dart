import 'package:tts_flow_dart/src/core/audio_spec.dart';
import 'package:tts_flow_dart/src/core/tts_request.dart';
import 'package:tts_flow_dart/src/core/tts_voice.dart';

final class TtsOutputSession {
  const TtsOutputSession({
    required this.requestId,
    required this.audioSpec,
    required this.voice,
    required this.options,
    this.params = const {},
  });

  final String requestId;
  final TtsAudioSpec audioSpec;
  final TtsVoice? voice;
  final TtsOptions? options;
  final Map<String, Object> params;
}
