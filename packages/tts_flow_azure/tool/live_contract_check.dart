import 'dart:io';

import 'package:tts_flow_azure/tts_flow_azure.dart';
import 'package:tts_flow_dart/tts_flow_dart.dart';

Future<void> main() async {
  final subscriptionKey = Platform.environment['AZURE_SPEECH_KEY']?.trim();
  final region = Platform.environment['AZURE_SPEECH_REGION']?.trim();
  if (subscriptionKey == null ||
      subscriptionKey.isEmpty ||
      region == null ||
      region.isEmpty) {
    stderr.writeln(
      'AZURE_SPEECH_KEY and AZURE_SPEECH_REGION are required for the Azure live contract.',
    );
    exitCode = 64;
    return;
  }

  final engine = AzureSpeechTtsEngine(
    config: AzureSpeechConfig(
      subscriptionKey: subscriptionKey,
      region: region,
      requestTimeout: const Duration(seconds: 30),
    ),
  );
  try {
    final chunks = await engine
        .synthesize(
          const TtsRequest(
            requestKey: 'azure-live-contract',
            text: 'Provider contract check.',
          ),
          SynthesisControl(),
          const TtsAudioSpec.mp3(),
        )
        .cast<TtsAudioChunk>()
        .toList();
    _verify(chunks);
    stdout.writeln('Azure live contract passed (${_byteCount(chunks)} bytes).');
  } finally {
    await engine.dispose();
  }
}

void _verify(List<TtsAudioChunk> chunks) {
  if (chunks.isEmpty || _byteCount(chunks) == 0 || !chunks.last.isLastChunk) {
    throw StateError('Provider returned no complete audio stream.');
  }
  if (chunks.any((chunk) => chunk.audioSpec.format != TtsAudioFormat.mp3)) {
    throw StateError('Provider returned an unexpected audio format.');
  }
}

int _byteCount(List<TtsAudioChunk> chunks) =>
    chunks.fold(0, (total, chunk) => total + chunk.bytes.length);
