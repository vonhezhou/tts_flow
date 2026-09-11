part of 'engine.dart';

/// Resolves built-in and application-supplied voice metadata for one model.
final class _OpenAiVoiceCatalog {
  const _OpenAiVoiceCatalog({
    required this.model,
    required this.defaultVoiceId,
    required this.overrides,
  });

  final String model;
  final String defaultVoiceId;
  final Map<String, List<TtsVoice>>? overrides;

  static const Map<String, List<TtsVoice>> _builtInCatalog = {
    'tts-1': [
      TtsVoice(voiceId: 'alloy'),
      TtsVoice(voiceId: 'echo'),
      TtsVoice(voiceId: 'fable'),
      TtsVoice(voiceId: 'nova'),
      TtsVoice(voiceId: 'onyx'),
      TtsVoice(voiceId: 'shimmer'),
    ],
    'tts-1-hd': [
      TtsVoice(voiceId: 'alloy'),
      TtsVoice(voiceId: 'echo'),
      TtsVoice(voiceId: 'fable'),
      TtsVoice(voiceId: 'nova'),
      TtsVoice(voiceId: 'onyx'),
      TtsVoice(voiceId: 'shimmer'),
    ],
    'gpt-4o-mini-tts': [
      TtsVoice(voiceId: 'alloy'),
      TtsVoice(voiceId: 'ash'),
      TtsVoice(voiceId: 'ballad'),
      TtsVoice(voiceId: 'coral'),
      TtsVoice(voiceId: 'echo'),
      TtsVoice(voiceId: 'fable'),
      TtsVoice(voiceId: 'nova'),
      TtsVoice(voiceId: 'onyx'),
      TtsVoice(voiceId: 'sage'),
      TtsVoice(voiceId: 'shimmer'),
      TtsVoice(voiceId: 'verse'),
    ],
  };

  static const List<String> _fallbackVoiceIds = [
    'alloy',
    'echo',
    'fable',
    'nova',
    'onyx',
    'shimmer',
  ];

  List<TtsVoice> resolve() {
    final override = overrides?[model];
    if (override != null) {
      return _withDefaultFallback(override);
    }
    final catalog = _builtInCatalog[model];
    if (catalog != null) {
      return _withDefaultFallback(catalog);
    }
    return _fallbackVoices();
  }

  List<TtsVoice> _withDefaultFallback(List<TtsVoice> discovered) {
    if (discovered.isEmpty) {
      return _fallbackVoices();
    }
    if (discovered.any((voice) => voice.isDefault)) {
      return discovered;
    }

    return discovered
        .map((voice) {
          if (voice.voiceId != defaultVoiceId) {
            return voice;
          }
          return TtsVoice(
            voiceId: voice.voiceId,
            locale: voice.locale,
            displayName: voice.displayName,
            isDefault: true,
          );
        })
        .toList(growable: false);
  }

  List<TtsVoice> _fallbackVoices() {
    return _fallbackVoiceIds
        .map(
          (voiceId) =>
              TtsVoice(voiceId: voiceId, isDefault: voiceId == defaultVoiceId),
        )
        .toList(growable: false);
  }
}
