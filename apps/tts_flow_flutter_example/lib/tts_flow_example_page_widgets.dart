part of 'tts_flow_example_page.dart';

class _SourceNotice extends StatelessWidget {
  const _SourceNotice({
    required this.usesGemini,
    required this.usesMimo,
    required this.usesAzure,
    required this.requestedSource,
    required this.hasAzureConfiguration,
  });

  final bool usesMimo;
  final bool usesGemini;
  final bool usesAzure;
  final String requestedSource;
  final bool hasAzureConfiguration;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isMisconfiguredAzure =
        requestedSource == 'azure' && !hasAzureConfiguration;
    final message = usesGemini
        ? 'Live source: Google Gemini Flash TTS. Audio streams to the speaker.'
        : requestedSource == 'gemini'
        ? 'Gemini source was requested, but GEMINI_API_KEY is missing. Using the bundled WAV sample.'
        : usesAzure
        ? 'Live source: Azure AI Speech. Azure returns streamed MP3 audio for the selected neural voice.'
        : usesMimo
        ? 'Live source: Xiaomi MiMo V2.5 TTS. Audio is synthesized remotely and streamed to the speaker.'
        : isMisconfiguredAzure
        ? 'Azure source was requested, but AZURE_SPEECH_KEY or AZURE_SPEECH_REGION is missing. Using the bundled WAV sample.'
        : 'Demo source: bundled WAV sample. Launch with --dart-define=MIMO_API_KEY=... for MiMo, or --dart-define=TTS_SOURCE=azure --dart-define=AZURE_SPEECH_KEY=... --dart-define=AZURE_SPEECH_REGION=... for Azure.';
    return Card(
      color: (usesMimo || usesAzure || usesGemini)
          ? theme.colorScheme.primaryContainer
          : theme.colorScheme.surfaceContainerHighest,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          children: [
            Icon(
              (usesMimo || usesAzure || usesGemini)
                  ? Icons.cloud_done
                  : Icons.info_outline,
            ),
            const SizedBox(width: 8),
            Expanded(child: Text(message)),
          ],
        ),
      ),
    );
  }
}

class _VoiceAndAudioControls extends StatelessWidget {
  const _VoiceAndAudioControls({
    required this.isReady,
    required this.voices,
    required this.selectedVoiceId,
    required this.voiceLabel,
    required this.onVoiceChanged,
    required this.volume,
    required this.minVolume,
    required this.maxVolume,
    required this.onVolumeChanged,
    required this.speed,
    required this.minSpeed,
    required this.maxSpeed,
    required this.onSpeedChanged,
    required this.pitch,
    required this.minPitch,
    required this.maxPitch,
    required this.onPitchChanged,
    required this.supportsControl,
    required this.sliderValue,
    required this.sliderDivisions,
  });

  final bool isReady;
  final List<TtsVoice> voices;
  final String? selectedVoiceId;
  final String Function(TtsVoice voice) voiceLabel;
  final ValueChanged<String?> onVoiceChanged;
  final double volume;
  final double minVolume;
  final double maxVolume;
  final ValueChanged<double> onVolumeChanged;
  final double speed;
  final double minSpeed;
  final double maxSpeed;
  final ValueChanged<double> onSpeedChanged;
  final double pitch;
  final double minPitch;
  final double maxPitch;
  final ValueChanged<double> onPitchChanged;
  final bool Function(double min, double max) supportsControl;
  final double Function(double value, double min, double max) sliderValue;
  final int? Function(double min, double max) sliderDivisions;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Voice & Audio Controls',
              style: Theme.of(context).textTheme.titleSmall,
            ),
            const SizedBox(height: 8),
            DropdownButtonFormField<String>(
              initialValue:
                  voices.any((voice) => voice.voiceId == selectedVoiceId)
                  ? selectedVoiceId
                  : null,
              isExpanded: true,
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                labelText: 'Voice',
              ),
              items: voices
                  .map(
                    (voice) => DropdownMenuItem<String>(
                      value: voice.voiceId,
                      child: Text(voiceLabel(voice)),
                    ),
                  )
                  .toList(growable: false),
              onChanged: isReady ? onVoiceChanged : null,
            ),
            const SizedBox(height: 8),
            _AudioControlSlider(
              label: 'Volume',
              value: volume,
              min: minVolume,
              max: maxVolume,
              isReady: isReady,
              onChanged: onVolumeChanged,
              supportsControl: supportsControl,
              sliderValue: sliderValue,
              sliderDivisions: sliderDivisions,
            ),
            _AudioControlSlider(
              label: 'Speed',
              value: speed,
              min: minSpeed,
              max: maxSpeed,
              isReady: isReady,
              onChanged: onSpeedChanged,
              supportsControl: supportsControl,
              sliderValue: sliderValue,
              sliderDivisions: sliderDivisions,
            ),
            _AudioControlSlider(
              label: 'Pitch',
              value: pitch,
              min: minPitch,
              max: maxPitch,
              isReady: isReady,
              onChanged: onPitchChanged,
              supportsControl: supportsControl,
              sliderValue: sliderValue,
              sliderDivisions: sliderDivisions,
            ),
          ],
        ),
      ),
    );
  }
}

class _AudioControlSlider extends StatelessWidget {
  const _AudioControlSlider({
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.isReady,
    required this.onChanged,
    required this.supportsControl,
    required this.sliderValue,
    required this.sliderDivisions,
  });

  final String label;
  final double value;
  final double min;
  final double max;
  final bool isReady;
  final ValueChanged<double> onChanged;
  final bool Function(double min, double max) supportsControl;
  final double Function(double value, double min, double max) sliderValue;
  final int? Function(double min, double max) sliderDivisions;

  @override
  Widget build(BuildContext context) {
    final supported = supportsControl(min, max);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          supported
              ? '$label: ${value.toStringAsFixed(2)} '
                    '(range ${min.toStringAsFixed(2)} - ${max.toStringAsFixed(2)})'
              : '$label: unsupported',
        ),
        Slider(
          min: supported ? min : 0.0,
          max: supported ? max : 1.0,
          divisions: sliderDivisions(min, max),
          value: sliderValue(value, min, max),
          onChanged: isReady && supported ? onChanged : null,
        ),
      ],
    );
  }
}
