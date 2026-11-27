# Playback platform verification

`JustAudioBackend` is exercised in ordinary unit tests on Linux and in native
integration jobs where an audio-player implementation is available. The table
below records automation, not a claim that every platform has been manually
verified.

| Target | Current regression coverage | Next evidence required |
| --- | --- | --- |
| Linux | Flutter unit tests in CI | A real-device playback pass if platform-specific behavior changes |
| macOS | Manual `macos-playback.yml` jitter and playback-control integration suites | Record workflow result for a release candidate |
| Windows | Manual `windows-playback.yml` jitter and playback-control integration suites with libmpv null output | Record a passing workflow result and verify device output on a Windows host |
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

## Test boundaries (2026-11-12)

PR and main-branch CI run `melos run check`, fixture-tool tests and coverage.
Tests under each package's `test/` directory use controlled external boundaries.
The following contracts are exercised offline.

| Boundary | Controlled dependency | Assertions |
| --- | --- | --- |
| MiMo HTTP | Injected mock HTTP client | Endpoint, authentication, request payload, SSE audio decoding, error mapping and client ownership |
| Gemini HTTP/SDK | Injected HTTP transport | Streaming audio, format validation, errors, cancellation and deadlines |
| Example Edge client | Injected fake SDK client | Voice/options mapping, audio-event boundaries and cancellation |
| JustAudioBackend | Injected mock `AudioPlayer`, explicit stream events and completion gates | Source preloading, underflow/recovery, late completion, pause acknowledgement, resume, cleanup, timeline and request attribution |
| Stream audio source | Direct `ChunkAudioSource.request()` calls | Immutable bytes, MIME type, byte ranges and source-start notification |
| Provider fixtures | Committed assets | Capture metadata, frame boundaries, byte preservation and arrival-offset validation |

The playback contract covers both an immediately resolved `play()` Future and
a Future that remains pending while source ingestion and finalization proceed.
Completion comes from the platform processing-state stream. Pause waits for
the player's acknowledgement, and resume preserves the queued source. These
tests control callback ordering without a native audio device or media clock.
Temporary-file tests also exercise file-output behavior in isolated directories.
Some deadline, throttling and cancellation tests still use real Dart timers;
the file-engine cancellation test includes a wall-clock upper bound. Those
cases remain sensitive to host scheduling and are candidates for virtual-clock
coverage.

The native suites in `integration_test/` load real player implementations and
system decoders. Their outcomes depend on runner audio configuration, codec
support, playback clocks and callback delivery. Windows/macOS workflows now
run through `workflow_dispatch`; use them for targeted platform diagnosis.
Their assertions continue to report failures. The separate scheduled
`Provider live contracts` workflow checks the configured MiMo service against
its real endpoint.

### Windows native EOF stall (November 27, 2026)

[Run 45922940401](https://github.com/vonhezhou/tts_flow/actions/runs/45922940401)
used `7e4e25c`: 33 jitter/format cases passed and Gemini PCM jitter timed out;
all five playback-control cases passed. The previous three zero-underflow
assertion failures no longer occurred. The stalled player reported
`index=3`, `sources=5`, `position=duration=320ms`, `playing=true`, `state=ready`;
source 4 contained 90,240 bytes but had never been requested. No attributed
native or backend playback error was emitted.

The installed `just_audio_media_kit` 2.1.0 adapter only forwards native EOF as
`completed` when its current index is the last playlist entry. Concurrently
appending another entry can suppress that notification. This is consistent
with the observed stall, though the exact Windows callback order remains
unconfirmed. The backend now also advances a queued next source when the
native `PlaybackEvent.updatePosition` reaches its positive duration while
ready and playing. It does not infer EOF from interpolated position updates,
advance paused playback, or synthesize request completion from position alone.
Queued callbacks recheck source identity and the latest native event.

Mock tests reproduce both append-before-EOF and append-after-EOF failures
with the old advancement condition and pass with the new condition; they
also cover stale EOF events, pause, and positions before the source end.
Local validation passed 36 Flutter unit tests, package static analysis, and
two macOS native smoke cases (Gemini PCM jitter and invalid Edge MP3).
Windows verification of this change is still pending; these local results
do not establish that the Windows stall is resolved.

### Earlier runner observations

On `d6bc1d6`, main CI passed on November 10. The November 12
Windows scheduled run passed 30 jitter/format cases and failed four; all five
playback-control cases passed. The November 9 macOS run on `748601f` passed
33 jitter/format cases and failed one, then skipped the control suite.

The supplied Windows log archive `logs_117009826621.zip` identifies all four
failures. Three cases completed playback and failed their zero-underflow
assertion: Gemini SDK mock transport observed one waiting event; MiMo long PCM
and MiMo continuous PCM each observed two. Captured arrival offsets and mock
HTTP bodies still run against the native player's clock. These cases now
validate waiting-event attribution, a unique completion and absence of playback
failure, following the existing Gemini PCM replay checks. Mock-player unit
tests cover zero underflow with explicitly controlled source availability.

The fourth case, Gemini continuous PCM, timed out after 15 seconds with
`index=3`, `sources=5`, `position=duration=320ms`, `playing=true`, and processing
state `ready`. Its history contained three completed/underflow cycles; the
diagnostic playback-error list was empty. Native logs also reported failed
`seek 0 absolute` commands. This remains an unresolved playback stall. Its
cause requires further platform diagnosis. The headless `ao=null` setup was
active, and all five playback-control tests passed, including the 137-source
MP3 case and its three forced-gap recoveries.

- [Main CI run](https://github.com/vonhezhou/tts_flow/actions/runs/42733424877)
- [Windows run](https://github.com/vonhezhou/tts_flow/actions/runs/43210550132)
- [macOS run](https://github.com/vonhezhou/tts_flow/actions/runs/42612987219)

### macOS AVFoundation failure (2026-11-16)

The archive `logs_118737931561.zip` records the macOS run on `d6bc1d6` with
Flutter 3.47.8 and the `macos-26-arm64` image `20261112.0504.1`. The jitter
suite passed 33 cases and failed `Captured Gemini PCM long fixture plays to
completion` during ingestion. AVFoundation reported `-11800`, `The operation
could not be completed`, at source index 2. The processing-state history was
`idle, loading, buffering, ready, idle`. The playback-control suite was skipped.
This generic native error does not identify its underlying cause.

The long fixture contains 1,210 PCM chunks of 1,920 bytes each. All chunks
are aligned for the declared 16-bit mono format. On November 17, a local
isolated replay and the complete 34-case jitter suite passed on macOS 27.2.1
with Flutter 3.47.9 / Dart 3.13.7. All 33 Flutter-adapter unit tests also passed.
The local OS and SDK differ from CI, so these results do not establish a fix
for the runner failure.

With the added diagnostics, the isolated Gemini long PCM case and both corrupt
buffered-payload cases passed. Static analysis of both integration test files
and the formatting check also passed.

Replay failures now include a snapshot from the player's native error stream
before backend cleanup, with the queue size, current index, position, duration,
processing state and nearby source sizes/frozen flags. They also include the
last twelve source-read notifications. macOS runs the playback-control suite
after a jitter-suite failure unless the job is cancelled, retaining the failed
job result.

The local five-case control sequence passed four cases, then timed out waiting
for source 128 in the long MiMo MP3 case. It had read 128 sources and recovered
from all three forced gaps at sources 34, 69 and 104. Cleanup had already
removed the queue when the original failure diagnostic ran. Source-read
timeouts now retain the player's state before synthesis-error cleanup.
An isolated follow-up passed with all 137 sources, 43.840 seconds of reported
audio and all three recoveries. The sequence failure remains unresolved, and
its relationship to the CI PCM failure is unconfirmed.

- [macOS run](https://github.com/vonhezhou/tts_flow/actions/runs/43861592232)

### Headless Windows CI output

The 2026-10-29 Windows run built successfully, then passed 17 jitter/format
cases and failed 17. The failures reported `There are no playback devices
available` from WASAPI and `could not open device` from OpenAL, followed by
`Could not open/initialize audio device -> no sound.` The playback-control
suite did not run because the first suite failed.

The initial workaround set `ALSOFT_DRIVERS=null`. On 2026-11-05, the jitter
suite passed 24 cases and failed ten. OpenAL device initialization errors were
absent, but playback-end timeouts, unexpected source-list underflows and native
seek errors remained. This result confirms that the first workaround was
insufficient; it does not establish the cause of every remaining failure.

The Windows workflow now passes `--dart-define=TTS_FLOW_HEADLESS_AUDIO=true`
to both test files. Their shared setup enables media_kit's exported
`NativePlayer.test` switch before player creation. In the resolved media_kit
1.2.6 implementation, this selects libmpv's own `ao=null` and `vo=null` outputs
instead of the OpenAL path. Native decoding and the real-time playback clock
remain active. The startup log identifies this mode with `NATIVE_TEST_AUDIO`.
The switch is restricted to the Windows tests; local runs without the define
retain device output. This is an upstream testing API, so review its behavior
when upgrading media_kit.

The direct WAV test now waits for `ProcessingState.completed` as well as the
play call: just_audio_media_kit 2.1.0 returns from its platform `play()` after
starting playback, so that Future alone cannot establish playback completion.
Playback-end timeouts now report source index/count, position, duration,
playing state, processing-state history, underflows and native errors.
The workflow runs the control suite even when the jitter suite fails, while
preserving the job failure. Cancellation still stops subsequent tests.

This revised configuration requires a Windows workflow rerun to determine
which remaining failures it resolves. It does not establish WASAPI
compatibility or audible output quality; verify those on a Windows host with
a playback device.

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
