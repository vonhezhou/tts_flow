# Azure Speech 本地配置（fish）

本仓库使用 Azure Speech 的区域 REST 接口，不需要安装 Speech SDK。
需要 `AZURE_SPEECH_KEY` 和 `AZURE_SPEECH_REGION` 两个环境变量。

没有 Azure 订阅也可以运行离线测试：

```sh
dart test packages/tts_flow_azure/test
cd apps/tts_flow_flutter_example
flutter test integration_test/just_audio_jitter_test.dart -d macos
```

协议测试使用模拟 HTTP；原生 MP3 回放使用明确标注的 `azure_simulated`
合成音频，详见 [fixture 覆盖与限制](provider_playback_fixtures.md)。
这些测试不表示 Azure 真实服务联调已经通过。

Speech F0 的 Neural TTS 每月有 50 万字符免费额度，但仍需要有效的 Azure 订阅。
Azure 免费试用的 200 美元额度最多使用 30 天；额度用完或试用期结束后，
不转为按量付费订阅，订阅及服务会停用。F0 资源档位与试用订阅是两回事。
参考 [Speech 定价](https://azure.microsoft.com/en-us/pricing/details/speech/)、
[免费试用到期规则](https://learn.microsoft.com/en-us/azure/cost-management-billing/manage/avoid-charges-free-account)。

## 1. 创建 Speech 资源

1. 登录 [Azure Portal](https://portal.azure.com/)，确认有可用订阅。
2. 搜索 **Speech / 语音服务**，创建 Speech 资源，选择订阅和资源组。
3. 选择支持文本转语音的区域，例如 **East Asia**，对应代码 `eastasia`。
   使用实际资源所在区域，不要直接照抄示例。
4. 测试优先选 **F0（免费）**（若可用）；S0 按用量收费。
   创建前查看页面显示的配额与价格。
5. 部署完成后，打开资源的 **Keys and Endpoint / 密钥和终结点**，
   复制 Key 1 或 Key 2，并记录 Location / Region 的代码。

这里需要 Speech 资源密钥，不是 Azure 登录密码、订阅 ID 或 OpenAI Key。
当前适配器拼接 `https://<region>.tts.speech.microsoft.com`，适用于 Azure 全球云。
世纪互联中国区使用不同域名，当前适配器不能仅靠修改 Region 使用该云。

## 2. 在 fish 中设置

在 fish 终端里执行以下命令；密钥通过隐藏输入读取，避免直接写入命令历史：

```fish
read -s -P 'Azure Speech Key: ' azure_speech_key_input
set -Ux AZURE_SPEECH_KEY "$azure_speech_key_input"
set -e azure_speech_key_input
set -Ux AZURE_SPEECH_REGION eastasia
```

`set -Ux` 会持久保存并导出给子进程。它是本地明文配置，勿提交 fish 配置文件。
若仅当前会话使用，换成 `set -gx`。从桌面启动的工具不一定继承 fish 变量；
需要时用 `fish -c '命令'` 启动子进程。

## 3. 在仓库根目录验证并采集

```fish
dart run packages/tts_flow_azure/tool/live_contract_check.dart
python3 tool/capture_provider_fixture.py capture azure
python3 tool/capture_provider_fixture.py jitter \
  apps/tts_flow_flutter_example/assets/fixtures/azure/continuous/manifest.json \
  --gap-after 0 --gap-ms 850
```

live contract 和采集都会请求服务、消耗配额。采集默认使用固定测试短句，
保存 24 kHz、48 kbps、单声道 MP3 分块与到达时间，不保存密钥或响应头。
采集目录已经存在时工具会拒绝覆盖；确定需要重新采集才加 `--overwrite`。
后续添加 Azure fixture 时，需要在示例 `pubspec.yaml` 显式声明各级样本目录，
并完成原生平台回放；Flutter 的普通目录资产声明不会递归包含所有子目录。

## 4. 启动 Flutter 示例

```fish
cd apps/tts_flow_flutter_example
flutter run -d macos \
  --dart-define=TTS_SOURCE=azure \
  --dart-define=AZURE_SPEECH_KEY="$AZURE_SPEECH_KEY" \
  --dart-define=AZURE_SPEECH_REGION="$AZURE_SPEECH_REGION"
```

环境变量供采集脚本和 Dart live contract 读取；Flutter 示例通过
`--dart-define` 读取配置，因此运行 App 时也需要上面的参数。
这仅用于本机开发；生产客户端的资源密钥应由后端保管。

## 常见错误

- **401**：确认密钥属于该 Speech 资源，Region 与资源一致。
- **403 / 无法连接**：检查资源网络访问策略、防火墙和本机网络。
- **429**：检查 F0 配额、并发和请求频率；稍后重试或按需升级。
- **找不到环境变量**：确认变量已导出，且命令由配置过变量的 fish 启动。

参考：[官方入门](https://learn.microsoft.com/en-us/azure/ai-services/speech-service/get-started-text-to-speech)、
[TTS REST 接口](https://learn.microsoft.com/en-us/azure/ai-services/speech-service/rest-text-to-speech)、
[配额](https://learn.microsoft.com/en-us/azure/ai-services/speech-service/speech-services-quotas-and-limits)。
