# Changelog

## 0.1.0

- M1: Added core contracts, models, and fake engine/output for validation.
- M2: Added TtsFlow FIFO queue orchestration, request/queue events, and control APIs.
- M3: Added request-scoped format negotiation and OpenAI non-streaming engine adapter.
- M4: Added production MemoryOutput and FileOutput with request-scoped session isolation.
- M5: Added SpeakerOutput baseline with backend abstraction and playback session artifact.
- M6: Added integration-style service tests, improved docs, and example application flow.

## Unreleased

- Breaking: `TtsFlow.speak(TtsRequest)` was replaced by
 `speak(String requestId, String text, [Map<String, Object> params])`.
- Breaking: `TtsFlow` now requires explicit `init()` before `speak` and
 control APIs; `init()` seeds service voice from `engine.getDefaultVoice()`.
- Added persistent service defaults for synthesis behavior:
 `voice`, `options`, and `preferredFormat`.
- Added direct option field accessors on `TtsFlow` for
 `speed`, `pitch`, `volume`, `sampleRateHz`, and `timeout`.
- `speak(...)` now constructs a fresh internal `TtsRequest` snapshot from
 current service defaults on each invocation (call params are per-request only).

- Added engine/service voice discovery APIs: `getAvailableVoices`,
 `getDefaultVoice`, and `getDefaultVoiceForLocale`.
- Expanded `TtsVoice` with optional metadata (`locale`, `displayName`,
 `isDefault`).
- `OpenAiTtsEngine` resolves available voices from a built-in model-scoped
 catalog (`tts-1`, `tts-1-hd`, `gpt-4o-mini-tts`) with deterministic locale
 fallback. Per-model overrides can be supplied via `voiceCatalogOverrides`.
