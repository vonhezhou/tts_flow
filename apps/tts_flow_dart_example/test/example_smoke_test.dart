import 'dart:io';

import 'package:test/test.dart';

void main() {
  test('offline example completes both requests with negotiated PCM', () async {
    final result = await Process.run(
      Platform.resolvedExecutable,
      ['lib/main.dart'],
      // 即使开发机配置了密钥，普通回归也不能访问真实服务。
      environment: {'MIMO_API_KEY': ''},
    );

    expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
    expect(result.stderr, isEmpty);
    final output = result.stdout as String;
    expect(output, contains('Running example in fake-engine mode'));
    for (final utteranceId in ['example-1', 'example-2']) {
      final summary = RegExp(
        '$utteranceId completed: format=pcm audioChunks=3 audioBytes=([0-9]+)',
      ).firstMatch(output);
      expect(summary, isNotNull, reason: output);
      expect(int.parse(summary!.group(1)!), greaterThan(0));
    }
  });
}
