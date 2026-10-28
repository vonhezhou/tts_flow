# Playback platform verification

`JustAudioBackend` is exercised in ordinary unit tests on Linux and in native
integration jobs where an audio-player implementation is available. The table
below records automation, not a claim that every platform has been manually
verified.

| Target | Current regression coverage | Next evidence required |
| --- | --- | --- |
| Linux | Flutter unit tests in CI | A real-device playback pass if platform-specific behavior changes |
| macOS | Weekly/manual `macos-playback.yml` jitter and playback-control integration suites | Record workflow result for a release candidate |
| Windows | Weekly/manual `windows-playback.yml` jitter and playback-control integration suites | Record workflow result for a release candidate |
| Android | None in CI | Run deterministic and Provider fixtures on a physical device or emulator |
| iOS | None in CI | Run deterministic and Provider fixtures on a physical device or simulator |
| Web | None in CI | Browser-specific manual or automated playback verification |

When a Provider fixture is introduced, run its `continuous`, `jitter`, and
`invalid` cases on each target in scope. Link the recorded result from the
release issue or changelog; do not infer a target's status from another native
runner.

For the jitter and playback-control regressions, use `dart run melos run
test:integration:macos` or `dart run melos run test:integration:windows` on
the corresponding desktop target.

## Local verification (2026-10-28)

On macOS with Flutter 3.47.7 (Dart 3.13.5), the offline jitter suite passed
31 cases and the playback-control suite passed five cases, including the
137-source MP3 regression. The synthetic MP3 fixtures now use the neutral
`synthetic_mp3` name; their audio bytes are unchanged. Run the two test files
with separate `flutter test` invocations, as the Melos scripts and native
workflows do; a directory-wide invocation failed to attach to the second app
locally after the first suite passed.

The workspace analysis and all 244 Dart/Flutter unit tests passed; the nine
Python fixture-tool tests passed. Dart-core line coverage was 76.59% and
Flutter-adapter line coverage was 77.37%, both above the 76% CI baseline.
These are local debug results; they do not establish Windows/mobile/Web
playback support or acoustic quality. No live provider request was made.
