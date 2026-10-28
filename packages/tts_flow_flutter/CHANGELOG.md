# Changelog

## Unreleased

- Upgrade `audio_decoder` to 0.8.1; keep the complete-payload conversion API.
- Add native MP3 decoding and 24/16 kHz PCM resampling regressions.
- Upgrade development lint rules to `very_good_analysis` 11 (Dart 3.13 tooling).
  The library's runtime Dart minimum remains unchanged.

## 0.2.0

- Declared `tts_flow_flutter` as a publishable public Flutter adapter package.
- Documented encoded-audio direct playback, explicit Decoder conversion, and
  the JustAudioBackend platform contract.
- Updated the core dependency to `tts_flow_dart ^0.2.0`.
