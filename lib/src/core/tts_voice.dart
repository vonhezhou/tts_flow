/// A class representing a TTS voice with its associated properties.
class TtsVoice {
  const TtsVoice({
    required this.voiceId,
    this.locale,
    this.displayName,
    this.isDefault = false,
  });

  final String voiceId;
  final String? locale;
  final String? displayName;
  final bool isDefault;
}
