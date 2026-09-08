# tts_flow_flutter_example

A new Flutter project.

## JustAudio 受控抖动回归

该 integration test 使用内置 PCM/WAV 样本，而非真实 Provider 或网络。它会等待
原生播放器加载第一段 source，再分别验证持续供给不触发 waiting，以及人为延迟
第二段时能触发 waiting、恢复并只完成一次。测试不依赖人工听音；运行时可能短暂播放
内置样本。

在 macOS 或 Windows 的真实桌面平台运行：

```sh
flutter test integration_test/just_audio_jitter_test.dart -d macos
```

将 `macos` 替换为 `windows` 或 `flutter devices` 显示的设备 ID。该测试不纳入普通
unit test CI；它是 Native player/平台配置的显式回归项。

当前 Flutter 工具会将此示例的 macOS target 迁移到 macOS 12.0，并使用 Swift Package
Manager 管理 Flutter 插件；因此 macOS 回归基线为 12.0 及以上。

## Getting Started

This project is a starting point for a Flutter application.

A few resources to get you started if this is your first Flutter project:

- [Learn Flutter](https://docs.flutter.dev/get-started/learn-flutter)
- [Write your first Flutter app](https://docs.flutter.dev/get-started/codelab)
- [Flutter learning resources](https://docs.flutter.dev/reference/learning-resources)

For help getting started with Flutter development, view the
[online documentation](https://docs.flutter.dev/), which offers tutorials,
samples, guidance on mobile development, and a full API reference.
