# Playback platform verification

`JustAudioBackend` is exercised in ordinary unit tests on Linux and in native
integration jobs where an audio-player implementation is available. The table
below records automation, not a claim that every platform has been manually
verified.

| Target | Current regression coverage | Next evidence required |
| --- | --- | --- |
| Linux | Flutter unit tests in CI | A real-device playback pass if platform-specific behavior changes |
| macOS | Weekly/manual `macos-playback.yml` jitter integration test | Record workflow result for a release candidate |
| Windows | Weekly/manual `windows-playback.yml` jitter integration test | Record workflow result for a release candidate |
| Android | None in CI | Run deterministic and Provider fixtures on a physical device or emulator |
| iOS | None in CI | Run deterministic and Provider fixtures on a physical device or simulator |
| Web | None in CI | Browser-specific manual or automated playback verification |

When a Provider fixture is introduced, run its `continuous`, `jitter`, and
`invalid` cases on each target in scope. Link the recorded result from the
release issue or changelog; do not infer a target's status from another native
runner.
