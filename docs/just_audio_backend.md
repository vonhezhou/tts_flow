# `JustAudioBackend` 设计说明

## 定位

`JustAudioBackend` 是 `tts_flow_flutter` 的跨平台扬声器后端。它的目标是将**持续到达、格式可直通的在线 TTS 音频**以低首包延迟播放到设备扬声器。

它不是 Dart 层的音频解码器、通用封装格式解析器或媒体处理图。

对调用方而言，它仍是普通的 `SpeakerBackend`：接收有序 `TtsChunk`、提供播放控制，并上报物理播放完成或失败事件。

## 核心策略：有限 Source 的渐进播放

`just_audio` 的 `StreamAudioSource` 不应被视为可长期悬挂的无限字节流。

在 Android、Windows、macOS 与 iOS 的实测中，source 已经开始播放后，若约 200ms 没有后续字节，底层播放链路可能静默断开；之后继续向同一个 source 写入数据不会恢复播放，也不会可靠地报告错误。

因此，本后端采用 source-list 的渐进播放策略：

```text
TTS 音频块持续到达
  → 将已到达的字节积累到当前有限 Source
  → just_audio 开始读取该 Source 后，将其冻结
  → 后续字节创建新的有限 Source 并追加到 source list
  → just_audio source-list 连续切换播放
```

`ChunkAudioSource.hasStarted` 是这个策略的关键边界：一旦平台开始读取该 source，后端绝不再试图向其中写入新数据。

这条路径面向已经具有合适音频边界的在线 TTS 输出，可以在合成结束前开始播放。它依赖上游分片和平台解码行为，不提供单个压缩流在任意字节边界上的持续解码能力。

### 选择该方案的已有经验

根据维护者此前使用 MiMo TTS、edge-tts 的开发观察，这两条 MP3 输出路径的每个音频分片都恰好落在完整 MP3 frame 边界，没有观察到将一个 frame 任意拆开的情况。这里的 edge-tts 指使用社区逆向接入的微软 Edge 浏览器 TTS 服务。这是当初采用有限 Source 渐进播放方案的依据：保留服务的音频分片边界，持续追加可供平台播放的片段，而不必等待整段合成结束。

上述记录属于特定服务路径的既有开发经验，不是服务方对所有模型、版本和平台的永久保证。仓库中的 MiMo MP3 样本已通过 macOS 回放；edge-tts 尚无本仓库的对应抓取样本和平台回归。AAC、Opus 的服务原生分片也没有这项经验支持，不能直接套用 MP3 的结论。

这里讨论的 MiMo MP3 历史使用路径与抓取样本，不改变当前 `tts_flow_mimo` adapter 的 PCM 输出契约。

需要区分三种边界：

- HTTP 读取块或 WebSocket 传输片段：传输层可能再次拆分数据，不能直接当成音频帧边界。
- 服务协议中的音频分片：adapter 应先重组协议消息，再输出音频，保留已验证的服务分片边界。
- 播放器的有限 Source：可能积累一个或多个完整音频分片；开始被平台读取后冻结，后续分片进入新 Source。

因此，原始 HTTP `read()` 返回什么就直接构造什么 `TtsAudioChunk`，与保留服务音频事件边界不是同一个契约。当前 backend 不会自动识别或修复帧边界。

## 无缝体验的前提

`JustAudioBackend` 的无缝播放承诺依赖以下条件：

1. 上游数据持续供给，后续 Source 在当前 Source 播尽前已能追加到播放列表；短暂网络抖动可能造成真实可听的停顿。
2. 原始音频本身连续、可由目标平台解码。一个请求内的编码参数突变、损坏数据或 Provider 产生的破音不能由播放列表修复。
3. 每个将要交给 `StreamAudioSource` 的有限字节序列适合被平台当作独立媒体输入；具体格式、容器和厂商扩展由 Provider adapter 负责。
4. 所选格式在目标平台的 just_audio 实现中经过验证。

这里的“独立媒体输入”不要求每段都是可单独保存和播放的完整音频文件；它要求的是该段在目标平台作为 source-list 的一项时，能够与相邻段连续解码和播放。

特别地，某些 Provider 可能在同一 TTS stream 内切换 MP3 采样率。即便字节边界完整，这仍可能破坏平台解码连续性；这属于 Provider 输出兼容性问题，而不是通用播放器应尝试修复的问题。

完整 MP3 frame 边界是重要的兼容性前提，但不等同于每段都是自包含文件，也不能单独证明可独立解码。帧间依赖、容器初始化信息和参数变化仍需结合目标平台的实际 Source 切换验证。

### 如何选择完整缓存模式

`bufferEncodedAudio` 默认是 `false`。MiMo、edge-tts 的历史 MP3 使用经验解释了原有渐进方案的适用场景；接入时保留服务音频分片，并完成目标平台验证后，可以继续采用该方案。不需要仅因输入是压缩音频而开启完整缓存。

| 输入契约与需求 | 选择 |
| --- | --- |
| 服务音频分片边界得到保留，编码参数兼容，且对应 Source-list 回放已在目标平台验证 | 保持默认 `false`，边合成边播放。 |
| 单个合法压缩文件被任意拆成网络块，或分片边界未知，且可以接受等待整段合成结束 | 显式开启 `true`，收齐后按一个完整文件播放。 |
| 任意分块的压缩流，同时要求低首播延迟 | 完整缓存不满足需求；选择服务可提供的 PCM 路径，或使用能够维持解码状态的持续流输出。 |
| PCM 输入 | 本选项不改变 PCM 的渐进播放方式。 |

选择依据是 adapter 输出的分片契约与平台验证结果，不是仅看 `mp3`、`aac` 或 `opus` 格式名。backend 不会自动探测是否需要缓存。完整缓存也不能修复损坏的原始音频、参数突变，或平台不支持的格式。

## 单个压缩文件的任意网络分块

默认有限 Source 模式要求每个冻结的 Source 适合作为目标平台 source-list 的有限媒体输入。单个 AAC/ADTS
流的半个帧、Ogg/Opus 文件的半个页，或者缺少 Ogg 头部的后续网络块，不满足这个条件。
仅保证所有块拼接后是合法文件，并不能保证默认渐进播放正确。

需要保留编码格式并回放这类输入时，可显式选择：

```dart
JustAudioBackend(
  bufferEncodedAudio: true,
  maxBufferedEncodedBytes: 64 * 1024 * 1024,
)
```

此模式按请求缓存所有压缩字节，在 `finalizePlayback()` 时创建一个已经填好数据的
有限 Source。它不做帧解析、解码或重编码，也不需要额外的编解码依赖。PCM 仍走原有
渐进路径。默认压缩播放模式不变，调用方应根据上游分块契约显式选择。

代价是等待整条压缩流收齐后才能首播；网络暂停体现为首播延迟，不是播放中的欠载与恢复。
该模式不能用来证明 AAC/Opus 支持低延迟边收边播。每个请求默认最多缓存 64 MiB；
超限会丢弃缓存并终止该会话，随后 finalize 也不会提交残缺前缀。finalize 前取消、reset
或 dispose 会释放待播会话，不向播放器提交其音频。需要 PCM 的完整载荷转换仍由 `Decoder` 负责。

2026-10-22 的 macOS 原生回归使用同一个 AAC 文件和同一个 Ogg Opus 文件，按字节拆开
同步字、容器头和载荷，分别验证连续供给和中间暂停 2500 ms。测试使用完整流缓存模式，
断言唯一完成事件、无播放错误，以及约 2.72 秒的完整语音时长。另有损坏文件失败回归。
原有独立片段的延迟供给测试保留，仍验证默认渐进路径中的等待与恢复。

这里人为拆开 AAC 帧和 Ogg 页的测试是对任意网络分块输入的覆盖，不代表 MiMo、edge-tts 的实际 MP3 输出会这样分片，也不代表 AAC、Opus 本身不适合流式播放。当前缺少的是对任意压缩字节分块维持连续解码状态的通用路径；已有符合分片契约的 TTS 渐进播放仍然是默认方案。

## Provider 与格式的责任边界

`JustAudioBackend` 不实现通用 MP3、ADTS、Ogg/Opus 或厂商私有音频流的 packetizer。

原因是这些格式、容器和扩展差异过大；通用 parser 既会显著扩大 Flutter 包复杂度，也无法修复编码参数突变或 Provider 级音频质量问题。

职责划分如下：

| 层 | 职责 |
| --- | --- |
| Provider adapter / `TtsEngine` | 知道上游协议，选择可稳定播放的输出格式；必要时决定适合 Source 断开的边界；对已知异常流提供降级或明确失败。 |
| `JustAudioBackend` | 冻结已经被平台读取的 source；按顺序追加有限 source；维护播放列表、播放控制和播放事件。 |
| `tts_flow` core | 传递 `TtsChunk`、`TtsAudioSpec`、取消和错误语义；不解析私有 bitstream。 |
| 应用 / 外部音频系统 | 对有混音、DSP、特殊协议修复等需求，使用自定义输出或专门的音频系统。 |

初期不必为每个 chunk 增加复杂的通用帧元数据。应先在文档和 Provider adapter 中维护“已验证适合 source-list 播放”的兼容性。只有出现多个真实 Provider 都需要表达同一种边界语义时，才为核心模型增加最小的、与具体编解码无关的边界标记。

## 会话状态与完成语义

一个 playback session 的真实状态应与单个 Source 的完成状态分离：

```text
receiving
  ├─ mutable source：尚未被平台读取，可继续累积
  ├─ sealed source：已被读取，不可再写入
  └─ waiting-for-next-source：当前 source 已播尽，但上游尚未 finalize

finalized
  └─ tail source 播尽 → playback completed
```

关键规则：

- 单个 source 播尽不等于整个 TTS 请求播放完成。
- 只有 `finalizePlayback()` 已被调用，且最后一个 source 播尽时，才能发出 `SpeakerPlaybackCompletedEvent` 并清理 session。
- 若未 finalized 的 source 播尽，保留 session；后续数据到达时追加新 source 并从完成状态恢复播放。
- 停止、重置、播放器错误和 dispose 都必须显式终止 session，不能伪装成正常播放完成。

这种模型允许在网络抖动时尽力续播；它不能承诺消除供数不足造成的听感间隙。

## 延迟与缓冲

后端以“尽快开始播放”为默认目标，并利用 source 在真正被平台请求前的短窗口积累尽可能多的数据。

不应把约 200ms 的实测断流阈值直接变成全平台常量。若需要调节，应通过经过设备矩阵验证的后端配置提供，例如：

- 首段最小数据量或估计时长；
- 单个 source 的目标时长；
- 待播放 source 的最大数量/总字节数。

这些配置只服务于 source-list 的稳定性和延迟权衡，不触发 Dart 层解码或重编码。

## 平台要求与能力声明

`StreamAudioSource` 在部分原生平台依赖 just_audio 的 localhost HTTP proxy。宿主应用需要完成相应配置：

- Android release：网络权限，以及只对 localhost 放行的 cleartext 网络策略；
- iOS/macOS：使用 proxy 所需的 ATS 配置；
- macOS sandbox：网络 client entitlement；
- Web：按“分段渐进播放”测试，不承诺单 source 无限推送或无缝切换。

`JustAudioBackend.supportedCapabilities` 只能声明已在目标平台和封装方式上验证的格式。格式名本身不足以说明可播放性，例如 AAC/Opus 的容器与帧化方式会影响原生解码器行为。

跨平台基线应先以经测试的 MP3 和 PCM/WAV 为准；AAC、Opus 或特定厂商流应在建立平台矩阵后逐项开放或由 Provider adapter 限定。

## 错误、控制与并发

`tts_flow` 对 `TtsOutput` 的音频写入严格串行。这里的 backend 串行操作队列是同一原则在播放器侧的延续：它保护单个播放器的 source-list 状态，不表示 core 支持或需要多请求混播。

- 后端必须监听 `AudioPlayer.errorStream`，将异步平台解码错误关联到活跃 `playbackId` 并终止该 session。
- `JustAudioBackend.playbackErrorStream` 保留 just_audio 的原始 `PlayerException`，供平台诊断；同时它通过可选的 `SpeakerPlaybackFailureAwareBackend` 能力发出标准 `SpeakerPlaybackFailedEvent`。`SpeakerOutput`、`MulticastOutput`、`PrioritizedOutput` 和 `TtsFlow.requestEvents` 会将其继续传递为 `TtsOutputPlaybackFailedEvent` 与 `requestPlaybackFailed`。
- `requestPlaybackFailed` 是独立的物理播放终态：它不向已经完成的 `TtsRequestHandle` chunk stream 补抛错误，也不追溯修改此前的 `requestSynthesisCompleted`，更不触发合成队列的 fail-fast 策略。调用方应使用它提示播放失败、记录诊断或自行发起新的播放请求。
- `playbackWaitingStream` 是非终态诊断信号：未 finalized 的 source-list 耗尽时发出，后续 chunk 仍可创建新 source 并恢复。它为模拟器、真机和单元测试提供可自动断言的抖动指标，不等同于解码错误。
- `playbackSourceStartedStream` 在原生播放器第一次请求某个 source 时发出。它对应 `ChunkAudioSource.hasStarted` 从 false 变为 true 的精确边界，可用于受控回归的供给时序门控；不要用各平台语义不同的 `ProcessingState.ready` 推断这个边界。
- 每个被冻结的 `ChunkAudioSource` 都是一个有限的、支持 HTTP byte-range 的 source。播放器若重试或按 range 读取，backend 必须返回与声明的 `sourceLength`、`contentLength`、`offset` 一致的快照，不能无视 `request(start, end)` 后仍返回完整流；这对 macOS AVFoundation 尤其重要。
- `AudioPlayer.play()` 的 Future 在播放结束、暂停或停止后才完成，不能在 source-list 的串行操作队列中 await；启动播放必须后台跟踪，以便后续 chunk 能在当前 source 播尽前继续追加。
- `stopPlayback()` 是清理操作，必须容忍播放器错误已经异步移除了同一 session；否则服务 dispose 会以二次停止错误遮蔽原始播放失败。
- Linux/Windows 使用默认的 `just_audio_media_kit` 时，必须在构造第一个 `AudioPlayer` 前调用 `JustAudioMediaKit.ensureInitialized()`。`JustAudioBackend` 自己保证此顺序；只在 `init()` 内调用已经太晚。macOS 默认仍使用 just_audio 原生实现；若应用显式配置 media_kit 接管 macOS，则应在创建 backend 前完成那项全局配置。
- `addAudioSource`、移除 source、seek、play、stop 与处理 completed 回调必须进入同一个串行操作队列，防止 await 期间互相交错。
- `pausePlayback`、`resumePlayback`、`stopPlayback` 必须能作用于合成已结束但设备仍在播放的 session；上层需要保留对应 playback handle。
- 所有内部 `StreamController` 在 dispose 时关闭。句子时间等语义 chunk
  由 `TtsFlow.speak()` 返回的 `TtsRequestHandle` 交给阅读层，不经播放器后端转发；后端只
  通过可选的 `PlaybackTimelineReporter` 提供物理播放位置。

## 非目标

- 将有限 source 拼接为一个永不结束的 `StreamAudioSource`。
- 在 backend 内实现通用 packetizer、转码、重采样或 DSP。
- 自动修复 Provider 的采样率变化、编码突变或损坏流。
- 保证任意格式、任意 Provider、任意平台组合上的无缝播放。
- 实现通用音频处理图。

## 验证策略

单元测试验证状态机和 source-list 操作；真实可靠性必须来自设备集成测试。

模拟器可以先验证播放控制和事件状态；真机负责实际格式兼容性、出声延迟、音频焦点和
路由切换等设备行为。[控制、长 MP3 与延迟回归说明](playback_regression.md)列出了
可执行命令、观测字段和模拟器/真机分工，避免把平台请求 Source 的时间当成实际出声时间。

最低测试集：

1. 当前 source 播尽而请求未 finalized，后续 source 到达后能继续播放且不会重复 completed。
2. finalized 后尾 source 播尽，只发出一次 completed 并释放 session。
3. append、stop、播放器 completed 与播放器 error 交错时，session 不泄漏、不误删。
4. 以真实 Provider 抓取的正常流、网络抖动流和异常流回归测试。
5. Android、iOS、macOS、Windows、Linux、Web 的 release 运行验证；分别记录首包到播放、停顿和错误表现。

### Provider × 平台回归的最小可行做法

不需要先拥有完整设备农场。回归样本和设备覆盖应分开管理：每份 Provider 样本可以在现有的一台真机或桌面设备上运行，设备矩阵只是逐步累积的验证记录，而不是阻止接入的前置条件。

每个 Provider/格式组合至少准备三段可脱敏、可复放的样本及其元数据：正常连续流、真实网络抖动流，以及已知异常流（例如采样率切换或损坏流）。元数据至少记录格式/容器、采样率、chunk 字节数与到达相对时间；密钥、完整文本和用户音频不得提交到仓库。

在任一可用真机上，使用 release 构建记录以下结果：首个音频 chunk 到开始出声的时间、可听停顿次数、`requestPlaybackFailed`/`playbackErrorStream` 事件，以及是否收到最终 `requestPlaybackCompleted`。对未覆盖平台只记录为“未验证”，不从结果推断跨平台成功。

当 Provider 可用时，优先把它接入示例应用的显式测试入口；凭据通过运行环境或本地未跟踪配置传入。捕获到的时序样本则可作为不依赖网络的回归夹具，用于复现某个平台问题。

## 当前实现的演进原则

后续修改必须优先保护这条路径：

```text
已验证的在线 TTS 压缩流 → JustAudioBackend → source-list 无缝播放
```

如果某项改动需要在 Dart 中解码、猜测私有 bitstream 或引入通用媒体图，它不应成为该 backend 的默认能力。
