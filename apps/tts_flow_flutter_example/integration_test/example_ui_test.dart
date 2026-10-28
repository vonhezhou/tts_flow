import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:tts_flow_flutter_example/main.dart';
import 'package:tts_flow_flutter_example/example_source_selector.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'example playback controls and source switching work at compact width',
    (tester) async {
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.binding.setSurfaceSize(const Size(1280, 1000));
      await tester.pumpWidget(
        const MyApp(mimoApiKey: 'ui-test-placeholder', ttsSource: 'sample'),
      );
      await tester.pump(const Duration(seconds: 2));
      await tester.pump(const Duration(milliseconds: 500));
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('Reader').first);
      await tester.pump(const Duration(seconds: 1));
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('Read passage'));
      await tester.pump(const Duration(milliseconds: 400));
      await tester.tap(find.text('Stop').first);
      await tester.pump(const Duration(milliseconds: 300));
      await tester.binding.setSurfaceSize(const Size(390, 844));
      await tester.pump(const Duration(milliseconds: 400));
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('Speaker').first);
      await tester.pump(const Duration(milliseconds: 500));
      expect(tester.takeException(), isNull);
      await tester.ensureVisible(find.text('Speak'));
      await tester.tap(find.text('Speak'));
      await tester.pump(const Duration(milliseconds: 800));
      await tester.ensureVisible(find.text('Pause'));
      await tester.tap(find.text('Pause'));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('Resume'), findsOneWidget);
      await tester.tap(find.text('Resume'));
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.text('Stop Current'));
      await tester.pump(const Duration(milliseconds: 300));
      await tester.ensureVisible(find.text('Events'));
      expect(find.textContaining('Speak failed:'), findsNothing);
      expect(
        find.textContaining('request requestSynthesisFailed'),
        findsNothing,
      );
      expect(tester.takeException(), isNull);
      await tester.tap(find.byType(DropdownButtonFormField<ExampleTtsSource>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('MiMo').last);
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.byTooltip('Key from environment'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(milliseconds: 500));
      await tester.binding.setSurfaceSize(null);
    },
  );
}
