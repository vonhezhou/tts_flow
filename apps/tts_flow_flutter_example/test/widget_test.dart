import 'package:flutter_test/flutter_test.dart';
import 'package:tts_flow_flutter_example/main.dart';

void main() {
  testWidgets('renders TtsFlow example shell', (WidgetTester tester) async {
    await tester.pumpWidget(const MyApp());

    expect(find.text('TtsFlow + JustAudioBackend'), findsOneWidget);
    expect(find.text('Text to synthesize'), findsOneWidget);
    expect(find.text('Speak'), findsOneWidget);
  });
}
