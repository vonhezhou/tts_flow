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

An additional explicit Edge TTS capture later on 2026-10-28 succeeded with
`dart_edge_tts` commit `cd02058c512e1beca5ec69eb83889304e97ea182`.
Its three new offline macOS cases pass: normal MP3 playback, derived supply-gap
waiting/recovery, and corrupt MP3 rejection. The asset test verifies complete
MP3 frame boundaries in all 65 captured events. See the
[capture details](provider_playback_fixtures.md#captured-edge-mp3-samples-2026-10-28).

The Flutter example's 28 unit/asset/configuration tests also pass after adding
source selection and local development-key storage. Its explicitly enabled
`edge_example_live_test.dart` passed on macOS, exercising voice loading,
fixed-text online synthesis and native playback through the example UI.
MiMo/Gemini credential interactions are tested offline; this change does not
claim a new live acceptance result for either paid provider.

## SDK refresh (2026-10-28)

The workspace now pins Flutter 3.47.8 / Dart 3.13.7 in `.fvmrc`; all CI setup
steps read that file. Melos 8.10 recognizes all six workspace packages and runs
the existing scripts without configuration migration. Direct dependencies
were upgraded and their constraints tightened to the newest jointly resolvable
versions. SDK/upstream-pinned transitive dependencies remain compatible without
`dependency_overrides`; published-library SDK minimums are unchanged.

All 258 Dart/Flutter tests, nine Python fixture-tool tests and strict workspace
analysis passed on the new SDK. The upgraded coverage 1.16 collector and LCOV
formatter produced 76.59% Dart-core and 77.37% Flutter-adapter line coverage,
both above the unchanged 76% baseline.

The first sequential native control run passed four short cases, then failed
while ingesting the long MiMo MP3 with a generic `internalError`. That initial
error did not retain enough diagnostic detail to establish its underlying
cause. The regression now reports the nested cause, recent Source reads,
waiting indices and native player state on failure, without changing its
timeouts or success assertions. An isolated diagnostic run passed: all 137
Sources were read, played duration was 43.840 seconds, and gaps after Sources
34, 69 and 104 recovered. This isolated pass alone does not establish that the
first failure has been fixed.

The subsequent complete control sequence also passed all five cases, including
the same 137-Source long sample and all three recoveries. Final native results
on Flutter 3.47.8: 34 jitter/format cases, five playback-control cases, two
native Decoder cases and one example UI/control case passed (42 total).
The initial failure remains unattributed; neither timeouts nor assertions were
relaxed to obtain these results. These local macOS checks do not establish
Windows/mobile/Web playback support or acoustic quality.
