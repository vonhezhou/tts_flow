part of 'tts_flow_example_page.dart';

/// Builds the example's source-specific TTS service and recording output.
final class _ExampleServiceFactory {
  const _ExampleServiceFactory({required this.configuration});

  final ExampleSourceConfiguration configuration;

  Future<_ExampleServiceResources> create({
    required JustAudioBackend backend,
    required Logger log,
  }) async {
    final temporaryDirectory = await getTemporaryDirectory();
    // 每次切换来源独立存放，避免旧服务的异步收尾覆盖新服务的录音文件。
    final outputDirectory = await temporaryDirectory.createTemp(
      'tts_flow_example_',
    );
    final outputAudioPath = p.join(
      outputDirectory.path,
      configuration.source == ExampleTtsSource.edge
          ? 'tts_flow_example.mp3'
          : 'tts_flow_example.wav',
    );
    final sampleAudioPath = configuration.source == ExampleTtsSource.sample
        ? await _copySampleAudioToTemp(outputDirectory)
        : null;
    final engine = _createEngine(sampleAudioPath);
    final service = TtsFlow(
      engine: engine,
      defaultOutput: PrioritizedOutput(
        primary: SpeakerOutput(backend: backend),
        auxiliaries: [
          _RecordingAuxiliaryOutput(
            output: configuration.source == ExampleTtsSource.edge
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
    if (configuration.source == ExampleTtsSource.edge) {
      return EdgeExampleTtsEngine();
    }
    if (configuration.source == ExampleTtsSource.gemini) {
      return GeminiTtsEngine(apiKey: configuration.apiKey);
    }
    if (configuration.source == ExampleTtsSource.mimo) {
      return MimoTtsEngine(apiKey: configuration.apiKey);
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
