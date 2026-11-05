import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:media_kit/media_kit.dart';

/// 在无音频设备的 Windows CI 中使用 libmpv 自身的实时 null 输出。
void configureNativeTestAudio() {
  if (!const bool.fromEnvironment('TTS_FLOW_HEADLESS_AUDIO')) return;
  if (!Platform.isWindows) {
    throw UnsupportedError('Headless audio is only configured for Windows.');
  }

  // 上游提供的测试开关只将 ao/vo 设为 null，仍执行原生解码和播放时钟。
  NativePlayer.test = true;
  debugPrint('NATIVE_TEST_AUDIO: libmpv ao=null (headless Windows)');
}
