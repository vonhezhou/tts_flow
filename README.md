# tts_flow

`tts_flow` is an extensible online-TTS streaming framework for Dart and
Flutter. It keeps provider audio encoded on the low-latency playback path
whenever the target player supports that format.

for dart: [tts_flow_dart](./packages/tts_flow_dart/README.md)

for flutter: [tts_flow_flutter](./packages/tts_flow_flutter/README.md)

Architecture, scope, and extension boundaries: [architecture](./docs/architecture.md).
Migration and release baseline: [migrating to 0.2](./docs/migrating_to_0_2.md).

For the Flutter `just_audio` playback adapter's stream segmentation, lifecycle,
and platform requirements, see the [JustAudioBackend guide](./docs/just_audio_backend.md).
