import 'dart:io';

import 'package:tts_flow_dart/tts_flow_dart.dart';
import 'package:tts_flow_openai/tts_flow_openai.dart';

Future<void> main() async {
  final apiKey = Platform.environment['OPENAI_API_KEY']?.trim();
  if (apiKey == null || apiKey.isEmpty) {
    stderr.writeln('OPENAI_API_KEY is required for the OpenAI live contract.');
    exitCode = 64;
    return;
  }

  final engine = OpenAiTtsEngine.fromClientConfig(
    config: OpenAiClientConfig(
      apiKey: apiKey,
      requestTimeout: const Duration(seconds: 30),
      maxRetries: 0,
    ),
  );
  try {
    final chunks = await engine
        .synthesize(
          const TtsRequest(
            requestKey: 'openai-live-contract',
            text: 'Provider contract check.',
          ),
          SynthesisControl(),
          const TtsAudioSpec.mp3(),
        )
        .cast<TtsAudioChunk>()
        .toList();
    _verify(chunks, TtsAudioFormat.mp3);
    stdout.writeln(
      'OpenAI live contract passed (${_byteCount(chunks)} bytes).',
    );
  } finally {
    await engine.dispose();
  }
}

void _verify(List<TtsAudioChunk> chunks, TtsAudioFormat format) {
  if (chunks.isEmpty || _byteCount(chunks) == 0 || !chunks.last.isLastChunk) {
    throw StateError('Provider returned no complete audio stream.');
  }
  if (chunks.any((chunk) => chunk.audioSpec.format != format)) {
    throw StateError('Provider returned an unexpected audio format.');
  }
}

int _byteCount(List<TtsAudioChunk> chunks) =>
    chunks.fold(0, (total, chunk) => total + chunk.bytes.length);
