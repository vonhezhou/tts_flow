part of 'tts_flow_example_page.dart';

String _voiceLabel(TtsVoice voice) {
  final display = voice.displayName?.trim();
  if (display != null && display.isNotEmpty) {
    return '$display (${voice.voiceId})';
  }
  return voice.voiceId;
}

bool _supportsControl(double min, double max) => max > min;

double _normalizeControlValue(double value, double min, double max) {
  if (!_supportsControl(min, max)) {
    return value;
  }
  return value.clamp(min, max).toDouble();
}

double _sliderValue(double value, double min, double max) {
  if (!_supportsControl(min, max)) {
    return 0.0;
  }
  return value.clamp(min, max).toDouble();
}

int? _sliderDivisions(double min, double max) {
  if (!_supportsControl(min, max)) {
    return null;
  }
  final steps = ((max - min) * 20).round();
  if (steps < 1) {
    return 1;
  }
  return steps > 200 ? 200 : steps;
}

double _progressValue(Duration position, Duration total) {
  final totalMs = total.inMilliseconds;
  if (totalMs <= 0) {
    return 0;
  }
  return (position.inMilliseconds / totalMs).clamp(0, 1).toDouble();
}

String _formatDuration(Duration value) {
  final hours = value.inHours;
  final minutes = value.inMinutes.remainder(60);
  final seconds = value.inSeconds.remainder(60);
  final millis = value.inMilliseconds.remainder(1000);

  if (hours > 0) {
    return '$hours:${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
  }

  return '${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}.${(millis ~/ 10).toString().padLeft(2, '0')}';
}
