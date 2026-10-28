# tts_flow

`tts_flow` is an extensible online-TTS streaming framework for Dart and
Flutter. It keeps provider audio encoded on the low-latency playback path
whenever the target player supports that format.

for dart: [tts_flow_dart](./packages/tts_flow_dart/README.md)

for flutter: [tts_flow_flutter](./packages/tts_flow_flutter/README.md)

Architecture, scope, and extension boundaries: [architecture](./docs/architecture.md).
Migration and release baseline: [migrating to 0.2](./docs/migrating_to_0_2.md).
Provider stream-fixture policy: [provider playback fixtures](./docs/provider_playback_fixtures.md).

Google Gemini streaming TTS setup and offline validation:
[tts_flow_gemini](./packages/tts_flow_gemini/README.md).

For the Flutter `just_audio` playback adapter's stream segmentation, lifecycle,
and platform requirements, see the [JustAudioBackend guide](./docs/just_audio_backend.md).

The maintained online adapters are MiMo and Gemini. Azure and OpenAI adapters
are no longer included; third-party providers can implement `TtsEngine`.
Ordinary checks use committed fixtures and do not consume provider quota.

## Automated checks

- `CI` runs static analysis, package unit tests, and example asset/reader tests
  plus Python fixture-tool tests on pull requests and pushes to `main`.
  It uploads Dart-core and Flutter-adapter LCOV reports as a workflow artifact
  and rejects either report below the current 76% line-coverage baseline.
- `macOS playback regression` runs the native JustAudio jitter and
  playback-control regressions weekly and can be run manually.
- `Windows playback regression` runs the same native regression suites weekly and can
  be run manually. Target coverage and the remaining device evidence are
  recorded in [platform verification](./docs/platform_verification.md).
- `Provider live contracts` runs weekly only when the MiMo GitHub Actions
  secret is configured. It sends a short fixed text and checks that the audio
  stream is non-empty, complete, and in the expected format. Configure
  `MIMO_API_KEY` only when you intend to run the MiMo live check.
- `Release validation` is available manually for every publishable package. A
  release tag must identify exactly one package — for example
  `tts_flow_dart-v0.2.1` — and must match that package's `pubspec.yaml` version
  and top-level changelog entry before its publish dry-run begins.
