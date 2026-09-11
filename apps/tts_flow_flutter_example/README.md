# tts_flow_flutter_example

Deterministic playback and online-TTS integration example for
`tts_flow_flutter`.

## JustAudio 受控抖动回归

该 integration test 使用内置 PCM/WAV 样本，而非真实 Provider 或网络。它会等待
原生播放器加载第一段 source，再分别验证持续供给不触发 waiting，以及人为延迟
第二段时能触发 waiting、恢复并只完成一次。测试不依赖人工听音；运行时可能短暂播放
内置样本。

在 macOS 或 Windows 的真实桌面平台运行：

```sh
flutter test integration_test/just_audio_jitter_test.dart -d macos
```

在仓库根目录，macOS 可将常规全仓检查和这项原生回归合并为一条命令：

```sh
dart run melos run check:macos
```

将 `macos` 替换为 `windows` 或 `flutter devices` 显示的设备 ID。该测试不纳入普通
unit test CI；它是 Native player/平台配置的显式回归项。

当前 Flutter 工具会将此示例的 macOS target 迁移到 macOS 12.0，并使用 Swift Package
Manager 管理 Flutter 插件；因此 macOS 回归基线为 12.0 及以上。

## Purpose

This app is a deterministic playback and output-lifecycle demonstration for
`tts_flow_flutter`. By default it uses a bundled WAV fixture through
`FileTtsEngine`, so it can run without an online TTS account or API key.

## Xiaomi MiMo live source

Supply a MiMo API key at launch to use the real `MimoTtsEngine` source for the
Speaker tab. It streams 24 kHz PCM from MiMo and plays it through
`JustAudioBackend` while writing the auxiliary WAV file.

```sh
flutter run --dart-define=MIMO_API_KEY=your_key_here
```

Without that define, the example remains in deterministic bundled-WAV mode.
The key is deliberately not persisted or entered in the UI; do not bundle a
production key in a client app.

## Azure AI Speech live source

To use Azure Speech, provide the Speech resource key and its Azure region, and
explicitly select Azure so a key alone never unexpectedly triggers paid or
quota-backed requests. Azure returns MP3, so the example records an auxiliary
MP3 file instead of WAV in this mode.

```sh
flutter run \
  --dart-define=TTS_SOURCE=azure \
  --dart-define=AZURE_SPEECH_KEY=your_key_here \
  --dart-define=AZURE_SPEECH_REGION=eastasia
```

Use the same region that hosts the Speech resource. The example queries
Azure's regional voice list after startup, so the voice dropdown contains the
voices available to that resource. Keep production credentials on a backend;
these launch-time defines are intended only for development.

It demonstrates speaker playback, physical playback events, output writing,
and decoded WAV or MP3 export. It intentionally does not embed an online-provider
credential flow; provider credentials remain application-owned.

See the repository [architecture](../../docs/architecture.md) and the
[JustAudio backend notes](../../docs/just_audio_backend.md) for scope and
platform requirements.
