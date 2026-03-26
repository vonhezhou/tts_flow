import 'package:meta/meta.dart';
import 'package:tts_flow_dart/src/core/audio_spec.dart';
import 'package:tts_flow_dart/src/core/tts_output.dart';
import 'package:tts_flow_dart/src/core/tts_request.dart';
import 'package:tts_flow_dart/src/core/tts_voice.dart';

mixin TtsOptionsMixin {
  @protected
  TtsOptions get options;

  @protected
  set options(TtsOptions value);

  TtsVoice get voice;
  set voice(TtsVoice value);

  TtsAudioFormat get preferredFormat;
  set preferredFormat(TtsAudioFormat value);

  double? get speed => options.speed;

  set speed(double? value) {
    options = options.copyWith(speed: value);
  }

  double? get pitch => options.pitch;

  set pitch(double? value) {
    options = options.copyWith(pitch: value);
  }

  double? get volume => options.volume;

  set volume(double? value) {
    options = options.copyWith(volume: value);
  }

  int? get sampleRateHz => options.sampleRateHz;

  set sampleRateHz(int? value) {
    options = options.copyWith(sampleRateHz: value);
  }

  Duration? get timeout => options.timeout;

  set timeout(Duration? value) {
    options = options.copyWith(timeout: value);
  }

  @protected
  TtsRequest buildRequest({
    required String requestId,
    required String text,
    required Map<String, Object> params,
    TtsOutput? output,
  }) {
    return TtsRequest(
      requestId: requestId,
      text: text,
      voice: voice,
      preferredFormat: preferredFormat,
      options: options,
      params: Map<String, Object>.unmodifiable(
        Map<String, Object>.from(params),
      ),
      output: output,
    );
  }
}
