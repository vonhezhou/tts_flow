# Changelog

## 0.1.0

- M1: Added core contracts, models, and fake engine/output for validation.
- M2: Added TtsService FIFO queue orchestration, request/queue events, and control APIs.
- M3: Added request-scoped format negotiation and OpenAI non-streaming engine adapter.
- M4: Added production MemoryOutput and FileOutput with request-scoped session isolation.
- M5: Added SpeakerOutput baseline with backend abstraction and playback session artifact.
- M6: Added integration-style service tests, improved docs, and example application flow.

## Unreleased

- Added engine/service voice discovery APIs: `getAvailableVoices`,
 `getDefaultVoice`, and `getDefaultVoiceForLocale`.
- Expanded `TtsVoice` with optional metadata (`locale`, `displayName`,
 `isDefault`).
- `OpenAiTtsEngine` resolves available voices from a built-in model-scoped
 catalog (`tts-1`, `tts-1-hd`, `gpt-4o-mini-tts`) with deterministic locale
 fallback. Per-model overrides can be supplied via `voiceCatalogOverrides`.
