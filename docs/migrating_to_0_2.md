# Migrating to 0.2

`0.2.0` is the first release that locks the current online-TTS streaming
architecture and its public extension boundaries. It contains accumulated
breaking changes that were previously listed under `Unreleased` while the core
package still declared `0.1.0`.

## Package versions

Upgrade the core, Flutter adapter, and any provider adapters together:

```yaml
dependencies:
  tts_flow_dart: ^0.2.0
  tts_flow_flutter: ^0.2.0 # Flutter apps only
  tts_flow_openai: ^0.2.0 # only when used
  tts_flow_azure: ^0.2.0  # only when used
  tts_flow_mimo: ^0.2.0   # only when used
```

`tts_flow_flutter` is now a publishable public adapter package. It is no
longer marked `publish_to: none`.

## Request and output API changes

- Replace `await for (final chunk in flow.speak(...))` with
  `final handle = flow.speak(...); await for (final chunk in handle.chunks)`.
- `speak` now takes text directly and returns `TtsRequestHandle`. Pass an
  application correlation value with `utteranceId:`; do not use it as a unique
  transport or playback key.
- Replace `output:` in the `TtsFlow` constructor with `defaultOutput:`.
  Per-request output remains `flow.speak(text, output: ...)`.
- Replace the old output lifecycle names with `startWrite`, `writeChunk`,
  `finishWrite`, and `cancelWrite`; its context type is
  `TtsOutputWriteContext`.
- `TtsAudioFormat.wav` no longer exists. Negotiate `TtsAudioFormat.pcm` and
  write a WAV container at an explicit `WavFileOutput` boundary when needed.

## Limits, cancellation, and shutdown

- Replace `maxInputByteSize` with `maxInputCharacterCount`. The new value is
  counted as user-perceived characters, rather than bytes or UTF-16 code
  units.
- `TtsOptions.timeout` and `TtsFlow.timeout` were removed. Configure each
  online adapter's `requestTimeout`, which is the layer that owns the network
  request and can cancel it.
- `TtsFlow.dispose()` cancels active synthesis, waits for cooperative stream
  shutdown according to `TtsFlowConfig.activeSynthesisShutdownTimeout` (five
  seconds by default), then invokes engine disposal. Managed outputs are
  released only after the active stream has actually stopped.

## Multi-output behavior

- Use `MulticastOutput` only when every output must receive the full stream
  under shared backpressure.
- Use `PrioritizedOutput` for a playback-critical primary plus non-blocking
  observers. An observer implements `TtsAuxiliaryOutput` and owns its async
  queue, overflow/drop policy, errors, and finalization. See the
  [auxiliary reference](../apps/tts_flow_flutter_example/lib/auxiliary_output_example.dart).
- For a full application-level processing pipeline, consume the sole
  `TtsRequestHandle.chunks` subscription and build fanout outside this package.

See the [architecture boundary](architecture.md) and the core
[changelog](../packages/tts_flow_dart/CHANGELOG.md) for the complete rationale.
