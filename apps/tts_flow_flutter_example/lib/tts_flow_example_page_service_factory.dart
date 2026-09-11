part of 'tts_flow_example_page.dart';

/// Builds the example's source-specific TTS service and recording output.
final class _ExampleServiceFactory {
  const _ExampleServiceFactory({
    required this.usesMimo,
    required this.usesAzure,
    required this.mimoApiKey,
    required this.azureSpeechKey,
    required this.azureSpeechRegion,
  });

  final bool usesMimo;
  final bool usesAzure;
  final String mimoApiKey;
  final String azureSpeechKey;
  final String azureSpeechRegion;

  Future<_ExampleServiceResources> create({
    required JustAudioBackend backend,
    required Logger log,
  }) async {
    final outputDirectory = await getTemporaryDirectory();
    final outputAudioPath = p.join(
      outputDirectory.path,
      usesAzure ? 'tts_flow_example.mp3' : 'tts_flow_example.wav',
    );
    final sampleAudioPath = (usesMimo || usesAzure)
        ? null
        : await _copySampleAudioToTemp(outputDirectory);
    final engine = _createEngine(sampleAudioPath);
    final service = TtsFlow(
      engine: engine,
      defaultOutput: PrioritizedOutput(
        primary: SpeakerOutput(backend: backend),
        auxiliaries: [
          _RecordingAuxiliaryOutput(
            output: usesAzure
                ? Mp3FileOutput(outputAudioPath)
                : WavFileOutput(outputAudioPath),
            log: log,
          ),
        ],
      ),
    );
    return _ExampleServiceResources(
      service: service,
      engine: engine,
      outputDirectoryPath: outputDirectory.path,
      outputAudioPath: outputAudioPath,
    );
  }

  Future<String> _copySampleAudioToTemp(Directory outputDirectory) async {
    final sampleFile = File(
      p.join(outputDirectory.path, 'tts_flow_sample.wav'),
    );
    final assetData = await rootBundle.load(_sampleAudioAsset);
    await sampleFile.writeAsBytes(
      assetData.buffer.asUint8List(
        assetData.offsetInBytes,
        assetData.lengthInBytes,
      ),
      flush: true,
    );
    return sampleFile.path;
  }

  TtsEngine _createEngine(String? sampleAudioPath) {
    if (usesAzure) {
      return AzureSpeechTtsEngine(
        config: AzureSpeechConfig(
          subscriptionKey: azureSpeechKey.trim(),
          region: azureSpeechRegion.trim(),
        ),
      );
    }
    if (usesMimo) {
      return MimoTtsEngine(apiKey: mimoApiKey.trim());
    }
    return FileTtsEngine(
      engineId: 'bundled-wav-file',
      provider: WavFileContentProvider.fromWav(sampleAudioPath!),
      chunkSizeBytes: 4096,
      maxBytesPerSecond: 64000,
    );
  }
}

final class _ExampleServiceResources {
  const _ExampleServiceResources({
    required this.service,
    required this.engine,
    required this.outputDirectoryPath,
    required this.outputAudioPath,
  });

  final TtsFlow service;
  final TtsEngine engine;
  final String outputDirectoryPath;
  final String outputAudioPath;
}
