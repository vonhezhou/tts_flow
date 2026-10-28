# tts_flow_dart_example

在仓库根目录完成 `fvm flutter pub get` 后，进入本目录运行：

```sh
fvm dart run lib/main.dart
```

默认使用离线 `SineTtsEngine`，无需密钥。设置非空 `MIMO_API_KEY` 后会发送
两次真实 MiMo 请求；`MimoTtsEngine.requestTimeout` 控制网络请求超时。
示例使用 `NullOutput` 丢弃音频，不播放或保存文件。

示例通过当前公开 API 演示：

- `TtsFlow(defaultOutput: ...)` 和 `speak(text, utteranceId: ...)`。
- 每次 `speak` 后立即为 `TtsRequestHandle.chunks` 绑定唯一消费者，逐块统计音频，
  并区分 `TtsAudioChunk` 与语义元数据。
- 首个请求偏好 PCM，第二个偏好 MP3；当前两个引擎都只提供 PCM，第二个请求回退到
  PCM。修改服务偏好不会影响已入队请求的配置快照。
- 通过 `synthesisResult` 区分完成、停止和失败，打印实际协商格式；停止或失败设置
  非零退出码。该结果表示合成和输出写入终态，不代表物理播放完成。
- 在 `finally` 中取消事件订阅并释放服务资源。

运行离线冒烟回归：

```sh
fvm dart test
```

测试会清空子进程的 `MIMO_API_KEY`，验证两个请求完成、PCM 回退及非空音频，
并通过现有 `melos run test:dart` 纳入工作区检查。
