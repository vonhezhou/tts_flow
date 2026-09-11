import 'dart:io';

import 'package:tts_flow_dart/tts_flow_dart.dart';
import 'package:tts_flow_mimo/tts_flow_mimo.dart';

const _mimoPcm = TtsAudioSpec.pcm(
  PcmDescriptor(sampleRateHz: 24000, bitsPerSample: 16, channels: 1),
);

Future<void> main() async {
  final apiKey = Platform.environment['MIMO_API_KEY']?.trim();
  if (apiKey == null || apiKey.isEmpty) {
    stderr.writeln('MIMO_API_KEY is required for the MiMo live contract.');
    exitCode = 64;
    return;
  }

  final engine = MimoTtsEngine(
    apiKey: apiKey,
    requestTimeout: const Duration(seconds: 30),
  );
  try {
    final chunks = await engine
        .synthesize(
          const TtsRequest(
            requestKey: 'mimo-live-contract',
            text: 'Provider contract check.',
          ),
          SynthesisControl(),
          _mimoPcm,
        )
        .cast<TtsAudioChunk>()
        .toList();
    _verify(chunks);
    stdout.writeln('MiMo live contract passed (${_byteCount(chunks)} bytes).');
  } finally {
    await engine.dispose();
  }
}

void _verify(List<TtsAudioChunk> chunks) {
  if (chunks.isEmpty || _byteCount(chunks) == 0 || !chunks.last.isLastChunk) {
    throw StateError('Provider returned no complete audio stream.');
  }
  if (chunks.any((chunk) => chunk.audioSpec != _mimoPcm)) {
    throw StateError('Provider returned an unexpected audio format.');
  }
}

int _byteCount(List<TtsAudioChunk> chunks) =>
    chunks.fold(0, (total, chunk) => total + chunk.bytes.length);
