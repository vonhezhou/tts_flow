import 'dart:convert';
import 'dart:io';

import 'package:tts_flow_dart/tts_flow_dart.dart';
import 'package:tts_flow_gemini/tts_flow_gemini.dart';

/// Explicitly opt-in: sends only a fixed, non-user test phrase to Gemini.
Future<void> main(List<String> args) async {
  if (args.any((arg) => arg != '--capture-fixture')) {
    stderr.writeln(
      'Usage: dart run tool/live_contract_check.dart [--capture-fixture]',
    );
    exitCode = 64;
    return;
  }
  final key = Platform.environment['GEMINI_API_KEY']?.trim();
  if (key == null || key.isEmpty) {
    stderr.writeln('GEMINI_API_KEY is required. No request was made.');
    exitCode = 64;
    return;
  }
  final root = File.fromUri(Platform.script).parent.parent.parent.parent;
  final destination = Directory(
    '${root.path}/apps/tts_flow_flutter_example/assets/fixtures/gemini/continuous',
  );
  final capture = args.contains('--capture-fixture');
  if (capture && destination.existsSync()) {
    stderr.writeln('Fixture already exists; move it before capturing again.');
    exitCode = 64;
    return;
  }
  final temp = await Directory.systemTemp.createTemp('tts-flow-gemini-');
  final wav = File('${temp.path}/speech.wav');
  final flow = TtsFlow(
    engine: GeminiTtsEngine(apiKey: key),
    defaultOutput: WavFileOutput(wav.path),
  );
  try {
    await flow.init();
    final chunks = <TtsAudioChunk>[];
    final offsets = <int>[];
    final clock = Stopwatch();
    final request = flow.speak('This is a provider fixture.');
    await for (final chunk in request.chunks.cast<TtsAudioChunk>()) {
      if (chunks.isEmpty) clock.start();
      chunks.add(chunk);
      offsets.add(clock.elapsedMilliseconds);
    }
    final length = chunks.fold<int>(
      0,
      (sum, chunk) => sum + chunk.bytes.length,
    );
    if (length == 0 ||
        !chunks.last.isLastChunk ||
        chunks.any((chunk) => chunk.audioSpec != GeminiTtsEngine.audioSpec) ||
        await wav.length() != 44 + length) {
      throw StateError('Gemini returned no complete PCM stream or WAV output.');
    }
    final header = WavHeader.parse((await wav.readAsBytes()).sublist(0, 44));
    if (header.toPcmDescriptor() != GeminiTtsEngine.audioSpec.requirePcm) {
      throw StateError('Gemini TtsFlow output has an unexpected WAV header.');
    }
    if (capture) {
      await destination.create(recursive: true);
      final entries = <Map<String, Object>>[];
      for (var i = 0; i < chunks.length; i++) {
        final name = '${i.toString().padLeft(3, '0')}.bin';
        await File('${destination.path}/$name').writeAsBytes(chunks[i].bytes);
        entries.add({
          'file': name,
          'arrivalOffsetMs': offsets[i] - offsets.first,
        });
      }
      await File('${destination.path}/manifest.json').writeAsString(
        '${const JsonEncoder.withIndent('  ').convert({
          'provider': 'gemini',
          'format': 'pcm',
          'sampleRateHz': 24000,
          'channels': 1,
          'bitsPerSample': 16,
          'encoding': 'signedInt',
          'kind': 'continuous',
          'chunks': entries,
          'provenance': {'type': 'captured', 'model': 'gemini-3.1-flash-tts-preview', 'timing': 'adapter output relative to first audio chunk'},
        })}\n',
      );
      stdout.writeln(
        'Captured ${chunks.length} chunks to ${destination.path}.',
      );
    }
    stdout.writeln(
      'Gemini TtsFlow live contract passed ($length PCM bytes and valid WAV output).',
    );
  } finally {
    await flow.dispose();
    await temp.delete(recursive: true);
  }
}
