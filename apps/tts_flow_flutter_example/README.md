# tts_flow_flutter_example

Deterministic playback and online-TTS integration example for
`tts_flow_flutter`.

Requires Flutter 3.44 / Dart 3.12 or newer (Cupertino Icons 2.0 baseline).
CI and local native regressions use Flutter 3.47.7.

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

The Speaker tab has a `TTS source` selector for Bundled WAV, MiMo, Gemini and
experimental Edge. Switching sources stops the previous service and initializes
the selected engine. Playback controls remain scrollable on smaller windows.

The dark workspace uses a two-column Speaker layout on wide windows and a
single scrollable column on compact screens. Text/playback actions, voice
settings, playback timelines and event diagnostics are grouped into separate
panels. The Reader tab shares the same theme and keeps sentence highlighting.

Native UI/control regression (offline; covers 1280 px and 390 px layouts,
reader controls, speaker pause/resume/stop and source switching):

```sh
flutter test integration_test/example_ui_test.dart -d macos
```

## Android release signing

The checked-in application ID belongs to this demonstration app. A release
build uses the debug key only when `android/key.properties` is absent, so that
local `flutter run --release` remains usable. Do not distribute such an APK.

For a distributable build, copy `android/key.properties.example` to the ignored
`android/key.properties`, replace every value with a dedicated keystore, and
then build normally. The Gradle configuration fails early if that local file is
present but incomplete. A production app should use its own application ID and
secure CI secret store rather than committing a keystore or credential file.

## Xiaomi MiMo live source

Supply a MiMo API key at launch to use the real `MimoTtsEngine` source for the
Speaker tab. It streams 24 kHz PCM from MiMo and plays it through
`JustAudioBackend` while writing the auxiliary WAV file.

```sh
flutter run --dart-define=MIMO_API_KEY=your_key_here
```

Without that define, select MiMo in the app to configure a development key.

## Google Gemini live source

The optional `tts_flow_gemini` adapter uses the pure Dart `googleai_dart` SDK.
No Firebase setup is required. It streams Gemini 3.1 Flash TTS PCM to the
speaker while writing an auxiliary WAV file.

```fish
flutter run -d macos \
  --dart-define=TTS_SOURCE=gemini \
  --dart-define=GEMINI_API_KEY="$GEMINI_API_KEY"
```

Gemini is explicitly selected in the app or through `TTS_SOURCE`; a key alone
does not enable it. See
[adapter setup, offline tests and live capture](../../packages/tts_flow_gemini/README.md).

## API Key 输入与本地保存

MiMo、Gemini 的 Key 按以下优先级读取：`--dart-define`、应用进程环境变量、
本地 SharedPreferences。桌面进程可以读取继承的环境变量；从 IDE、手机或桌面图标
启动时建议使用 `--dart-define`，或直接在 App 中输入。

选中 MiMo/Gemini 且没有可用 Key 时弹出输入框。保存成功后启用该来源，下次选择时
直接复用；两者的 Key 分开存储。取消输入保留当前来源，首次启动取消则使用内置 WAV。
`API Key` 按钮可以修改或删除本地 Key；删除后切回离线样本。环境注入的 Key 优先，
不会自动持久化，也不能通过本地设置覆盖。

SharedPreferences 不加密，适合这台设备上的开发测试 Key。不要把生产 Key 随 App
分发；本例不会打印 Key 或把它写入音频样本。

## Edge 示例来源

选择 `Edge (experimental)`，或通过 `--dart-define=TTS_SOURCE=edge` 启动。
无需 API Key。示例使用固定 Git 版本的 `dart_edge_tts`，把原始 MP3 音频事件传给
`TtsFlow` 和 `JustAudioBackend`，辅助输出保存为 MP3；其他来源继续保存 WAV。
该服务接口非正式且可能失效，接入仅限示例 App，不加入框架的正式 Provider 包。
上游包注明仅限非商业使用。

显式联网验收（默认测试不访问 Edge）：

```sh
flutter test integration_test/edge_example_live_test.dart -d macos \
  --dart-define=RUN_EDGE_LIVE=true
```

此用例验证示例页面初始化、固定语句合成和原生播放完成，不验证声学质量。

See the repository [architecture](../../docs/architecture.md) and the
[JustAudio backend notes](../../docs/just_audio_backend.md) for scope and
platform requirements.

See the [native playback regression guide](../../docs/playback_regression.md)
for PCM/MP3 pause/resume, stop-and-replace, long MP3 supply-gap tests, and
diagnostic latency fields. Simulator runs validate control behavior; physical
devices and output recording are needed for acoustic and real latency claims.
