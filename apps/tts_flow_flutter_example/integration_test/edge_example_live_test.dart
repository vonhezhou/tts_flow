import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:tts_flow_flutter_example/tts_flow_example_page.dart';

// 只在显式传入 --dart-define=RUN_EDGE_LIVE=true 时访问非正式在线接口。
const _runLive = bool.fromEnvironment('RUN_EDGE_LIVE');

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('Edge example synthesizes and completes native playback', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(home: TtsFlowExamplePage(ttsSource: 'edge')),
    );
    await _waitFor(tester, find.textContaining('Ready using Edge TTS'));
    await tester.enterText(find.byType(TextField), '你好，这是示例应用的语音播放测试。');
    await tester.ensureVisible(find.text('Speak'));
    await tester.tap(find.text('Speak'));
    await _waitFor(
      tester,
      find.textContaining('request requestPlaybackCompleted'),
    );
    expect(find.textContaining('request requestPlaybackFailed'), findsNothing);
    expect(find.textContaining('Speak failed:'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(milliseconds: 500));
  }, skip: !_runLive);
}

Future<void> _waitFor(WidgetTester tester, Finder finder) async {
  final timer = Stopwatch()..start();
  while (finder.evaluate().isEmpty) {
    if (timer.elapsed > const Duration(seconds: 30)) {
      fail('Timed out waiting for $finder');
    }
    await tester.pump(const Duration(milliseconds: 100));
  }
}
