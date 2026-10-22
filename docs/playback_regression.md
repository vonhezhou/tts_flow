# 原生播放控制与延迟观测

这些测试以服务音频分片适合有限 Source 播放为前提，不处理任意压缩字节分片。
入口为 `apps/tts_flow_flutter_example/integration_test/playback_regression_test.dart`，
使用已入库的音频，不依赖服务凭据或网络请求。

## 覆盖内容

- PCM、MP3：合成已完成但设备仍在播放时暂停，观察位置保持，再恢复并完成。
- PCM、MP3：播放中停止，立即开始下一请求。两请求重用 `utteranceId`，
  断言终态按 `requestKey` 隔离，被停止请求不会随后收到正常播放完成事件。
- 长 MP3：保留 MiMo 的 137 个服务音频分片，逐一等到平台请求上一 Source 后再交付下一块，
  确保真正发生 137 项 Source 切换。在第 34、69、104 项耗尽后分别暂停供给 700 ms，
  验证三次恢复、唯一完成事件和 30–60 秒的总播放时长。

长样本来自此前已完成的 [MiMo MP3 复测](mimo_mp3_probe_2026-10-22.md)中 `narrative`
样本，共 448032 字节。原始分片和时序保存在 `mimo_mp3/long_continuous`；
压力测试保留字节和顺序，但显式改变交付时序，不声称复现真实服务延迟。
其独立分片与拼接解码的时长有差异；不把 FFmpeg 的裁剪行为当成原生播放器的定值，
也不根据完成事件断言没有填充静音或爆音。

## 延迟字段的含义

测试输出 `PLAYBACK_METRICS` JSON，供后续设备与版本比较：

| 字段 | 测量区间 |
| --- | --- |
| `requestToFirstAudioMs` | 本地 `speak()` 调用到首个音频 chunk 的请求事件。 |
| `firstAudioToSourceReadMs` | 首个音频事件到平台首次请求 Source 字节。 |
| `waitingToSourceReadMs` | 播放列表耗尽到后续 Source 被平台请求，包含人为供给暂停。 |
| `newAudioToSourceReadMs` | 恢复供给的音频事件到后续 Source 被平台请求。 |
| `sourceReadCount` | 该请求被平台读取的 Source 数量。 |
| `playedDurationMs` | 完成事件中后端汇报的累计媒体时长。 |

**首包来自离线回放，不是云服务首包延迟；Source 被读取也不等于扬声器已经出声。**
这些事件由同一个单调时钟观测，包含 Dart 事件分发开销，不能从中推断端到端出声延迟。
测试验证事件顺序、完整播放和恢复；输出单次观测值，不设置跨设备统一的毫秒级性能 SLA，
也不把一次运行当成 P95 等统计结果。

## 模拟器与真机如何分工

模拟器适合测试控制调用、位置保持与恢复、停止后的资源清理、后续请求播放、事件归属。
它可以作为开发和持续集成的第一道回归，不要求每次改动都使用真机。

真实音频格式兼容性与系统 codec 行为仍需目标真机验证。实际出声延迟、爆音和拼接间隙，
以及音频焦点、来电打断、后台、蓝牙/耳机切换等场景，不能由模拟器事件测试代替。
声学结论还需要录制或捕获实际输出。当前控制测试不覆盖这些设备场景。

性能验收使用目标真机的 profile/release 构建；debug 模式和模拟器数据仅用于功能诊断。
Flutter 的[构建模式说明](https://docs.flutter.dev/testing/build-modes)与
[性能测量指南](https://docs.flutter.dev/perf/ui-performance)也明确区分这两类环境。

## 运行方式

在 Flutter 示例目录执行：

```sh
# macOS：控制、延迟观测和长 MP3 压力回放。
flutter test integration_test/playback_regression_test.dart -d macos

# 用 flutter devices 获取已启动模拟器的 ID，只跑四项控制回归。
flutter test integration_test/playback_regression_test.dart -d <simulator-id> --plain-name native

# 真机 profile 跑完整套件，需要宿主工程正常的签名和设备配置。
flutter drive --driver test_driver/integration_test.dart \
  --target integration_test/playback_regression_test.dart -d <physical-device-id> --profile
```

iOS 示例工程使用 Flutter 生成的 Swift Package Manager 插件集成，最低部署版本为 iOS 15。
`Flutter/ephemeral` 下的生成依赖不入库；这里没有变更 Dart 包对宿主应用的版本声明。

## 已执行的验证（2026-10-22）

| 环境 | 结果 |
| --- | --- |
| macOS 原生，debug | PCM/MP3 四项控制回归通过；137 Source 长 MP3、三次欠载恢复通过。 |
| iPhone 17，iOS 26.5 Simulator，debug | PCM/MP3 四项控制回归通过；未执行长 MP3 压力回放。 |
| Android 模拟器、Android/iOS 真机 | 本次未验证。 |

macOS 长 MP3 单次观测中，首包到 Source 请求约 48.8 ms；三次欠载到重新请求约
736.7–743.7 ms，其中包含 700 ms 人为暂停；恢复供给到请求约 4.5–9.0 ms。
这些数值是调试构建的诊断记录，不是产品延迟承诺。

该压力测试还暴露并推动修复了一个时间线问题：`just_audio.durationStream` 会过滤相同值，
仅监听时长变化会漏记相邻等时长 Source。后端现在也在 Source 索引切换时登记当前时长；
对应单元回归验证三个 320 ms Source 汇总为 960 ms，位置偏移也连续累积。
