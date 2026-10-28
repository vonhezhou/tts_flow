import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tts_flow_flutter_example/example_source_selector.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  Future<void> pumpSettings(
    WidgetTester tester, {
    String source = '',
    String mimoKey = '',
    String geminiKey = '',
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ExampleSourceSelector(
            ttsSource: source,
            mimoApiKey: mimoKey,
            geminiApiKey: geminiKey,
            builder: (_, configuration) => Text(
              'active:${configuration.source.name}:${configuration.apiKey}',
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
  }

  testWidgets('default stays offline without asking for credentials', (
    tester,
  ) async {
    await pumpSettings(tester);
    expect(find.text('active:sample:'), findsOneWidget);
    expect(find.byType(AlertDialog), findsNothing);
  });

  for (final source in [ExampleTtsSource.mimo, ExampleTtsSource.gemini]) {
    testWidgets(
      '${source.name} prompts, validates, saves and reloads its own key',
      (tester) async {
        await pumpSettings(tester, source: source.name);
        expect(find.text('${source.label} API Key'), findsOneWidget);
        await tester.tap(find.text('Save'));
        await tester.pump();
        expect(find.text('Please enter an API Key.'), findsOneWidget);
        await tester.enterText(
          find.byType(TextField),
          '  development-test-key  ',
        );
        await tester.tap(find.text('Save'));
        await tester.pumpAndSettle();
        expect(
          find.text('active:${source.name}:development-test-key'),
          findsOneWidget,
        );
        final preferences = await SharedPreferences.getInstance();
        expect(
          preferences.getString(source.preferenceKey),
          'development-test-key',
        );
        final other = source == ExampleTtsSource.mimo
            ? ExampleTtsSource.gemini
            : ExampleTtsSource.mimo;
        expect(preferences.containsKey(other.preferenceKey), isFalse);

        await tester.pumpWidget(const SizedBox());
        await pumpSettings(tester, source: source.name);
        expect(find.byType(AlertDialog), findsNothing);
        expect(
          find.text('active:${source.name}:development-test-key'),
          findsOneWidget,
        );
      },
    );

    testWidgets('${source.name} environment key wins without being persisted', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({
        source.preferenceKey: 'local-key',
      });
      await pumpSettings(
        tester,
        source: source.name,
        mimoKey: source == ExampleTtsSource.mimo ? ' env-key ' : '',
        geminiKey: source == ExampleTtsSource.gemini ? ' env-key ' : '',
      );
      expect(find.text('active:${source.name}:env-key'), findsOneWidget);
      expect(find.byType(AlertDialog), findsNothing);
      expect(
        (await SharedPreferences.getInstance()).getString(source.preferenceKey),
        'local-key',
      );
    });
  }

  testWidgets('cancel missing startup key falls back to the sample', (
    tester,
  ) async {
    await pumpSettings(tester, source: 'gemini');
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(find.text('active:sample:'), findsOneWidget);
    expect((await SharedPreferences.getInstance()).getKeys(), isEmpty);
  });

  testWidgets('switching sources can cancel, then select Edge without a key', (
    tester,
  ) async {
    await pumpSettings(tester);
    await tester.tap(find.byType(DropdownButtonFormField<ExampleTtsSource>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('MiMo').last);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(find.text('active:sample:'), findsOneWidget);
    await tester.tap(find.byType(DropdownButtonFormField<ExampleTtsSource>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Edge (experimental)').last);
    await tester.pumpAndSettle();
    expect(find.text('active:edge:'), findsOneWidget);
    expect(find.byType(AlertDialog), findsNothing);
  });

  testWidgets('saved key can be replaced and deleted', (tester) async {
    SharedPreferences.setMockInitialValues({
      ExampleTtsSource.mimo.preferenceKey: 'old-key',
    });
    await pumpSettings(tester, source: 'mimo');
    await tester.tap(find.text('API Key'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.enterText(find.byType(TextField), 'new-key');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(find.text('active:mimo:new-key'), findsOneWidget);
    await tester.tap(find.text('API Key'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('Delete saved key'));
    await tester.pumpAndSettle();
    expect(find.text('active:sample:'), findsOneWidget);
    expect(
      (await SharedPreferences.getInstance()).containsKey(
        ExampleTtsSource.mimo.preferenceKey,
      ),
      isFalse,
    );
  });
}
