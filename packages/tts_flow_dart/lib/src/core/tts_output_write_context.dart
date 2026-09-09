import 'package:tts_flow_dart/src/core/audio_spec.dart';
import 'package:tts_flow_dart/src/core/tts_request.dart';
import 'package:tts_flow_dart/src/core/tts_voice.dart';

/// Request metadata supplied when [TtsOutput.startWrite] opens an output.
final class TtsOutputWriteContext {
  const TtsOutputWriteContext({
    required this.requestKey,
    required this.audioSpec,
    required this.voice,
    required this.options,
    this.params = const {},
  });

  TtsOutputWriteContext copyWith({
    String? requestKey,
    TtsAudioSpec? audioSpec,
    TtsVoice? voice,
    TtsOptions? options,
    Map<String, Object>? params,
  }) => TtsOutputWriteContext(
    requestKey: requestKey ?? this.requestKey,
    audioSpec: audioSpec ?? this.audioSpec,
    voice: voice ?? this.voice,
    options: options ?? this.options,
    params: params ?? this.params,
  );

  final String requestKey;
  final TtsAudioSpec audioSpec;
  final TtsVoice? voice;
  final TtsOptions? options;
  final Map<String, Object> params;
}
