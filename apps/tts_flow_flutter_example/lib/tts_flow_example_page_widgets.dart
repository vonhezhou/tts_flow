part of 'tts_flow_example_page.dart';

class _SourceNotice extends StatelessWidget {
  const _SourceNotice({required this.source});

  final ExampleTtsSource source;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final live = source != ExampleTtsSource.sample;
    final message = switch (source) {
      ExampleTtsSource.gemini =>
        'Live source: Google Gemini Flash TTS. Audio streams to the speaker.',
      ExampleTtsSource.mimo =>
        'Live source: Xiaomi MiMo V2.5 TTS. Audio streams to the speaker.',
      ExampleTtsSource.edge =>
        'Experimental Edge source: unofficial service, availability may change. No API Key required.',
      ExampleTtsSource.sample =>
        'Demo source: bundled WAV sample. Select an online source above to synthesize your text.',
    };
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            live ? Icons.cloud_outlined : Icons.offline_bolt_outlined,
            size: 18,
            color: theme.colorScheme.primary,
          ),
          const SizedBox(width: 10),
          Expanded(child: Text(message, style: theme.textTheme.bodySmall)),
        ],
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
    return ExampleSection(
      title: 'Voice & audio',
      icon: Icons.tune_rounded,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          DropdownButtonFormField<String>(
            initialValue:
                voices.any((voice) => voice.voiceId == selectedVoiceId)
                ? selectedVoiceId
                : null,
            isExpanded: true,
            decoration: const InputDecoration(
              labelText: 'Voice',
              prefixIcon: Icon(Icons.record_voice_over_outlined, size: 20),
            ),
            items: voices
                .map(
                  (voice) => DropdownMenuItem<String>(
                    value: voice.voiceId,
                    child: Text(
                      voiceLabel(voice),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
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
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(child: Text(label, style: theme.textTheme.bodyMedium)),
              Text(
                supported ? value.toStringAsFixed(2) : 'Unsupported',
                style: theme.textTheme.labelMedium?.copyWith(
                  color: supported
                      ? theme.colorScheme.primary
                      : theme.colorScheme.onSurfaceVariant,
                  fontFamily: 'monospace',
                ),
              ),
            ],
          ),
          Slider(
            min: supported ? min : 0.0,
            max: supported ? max : 1.0,
            divisions: sliderDivisions(min, max),
            value: sliderValue(value, min, max),
            onChanged: isReady && supported ? onChanged : null,
          ),
          Text(
            supported
                ? 'Range ${min.toStringAsFixed(2)} – ${max.toStringAsFixed(2)}'
                : 'Not available for this source',
            style: theme.textTheme.bodySmall?.copyWith(fontSize: 11),
          ),
        ],
      ),
    );
  }
}

class _PlaybackTimeline extends StatelessWidget {
  const _PlaybackTimeline({
    required this.label,
    required this.position,
    required this.duration,
  });

  final String label;
  final Duration position;
  final Duration duration;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: theme.textTheme.bodySmall?.copyWith(fontSize: 11)),
        const SizedBox(height: 10),
        LinearProgressIndicator(value: _progressValue(position, duration)),
        const SizedBox(height: 10),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              _formatDuration(position),
              style: theme.textTheme.labelLarge?.copyWith(
                fontFamily: 'monospace',
              ),
            ),
            Text(
              _formatDuration(duration),
              style: theme.textTheme.bodySmall?.copyWith(
                fontFamily: 'monospace',
              ),
            ),
          ],
        ),
      ],
    );
  }
}
