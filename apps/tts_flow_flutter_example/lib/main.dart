import 'package:flutter/material.dart';
import 'package:logging/logging.dart';
import 'package:logging_appenders/logging_appenders.dart';
import 'package:tts_flow_flutter_example/tts_flow_example_page.dart';

void main(List<String> args) {
  Logger.root.clearListeners();
  Logger.root.level = Level.ALL;
  PrintAppender(formatter: ColorFormatter()).attachToLogger(Logger.root);

  runApp(MyApp(useXiaomiTts: _parseUseXiaomiArg(args)));
}

class MyApp extends StatelessWidget {
  const MyApp({required this.useXiaomiTts, super.key});

  final bool useXiaomiTts;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'TtsFlow Speaker Example',
      theme: ThemeData.dark(),
      home: TtsFlowExamplePage(useXiaomiTts: useXiaomiTts),
    );
  }
}

bool _parseUseXiaomiArg(List<String> args) {
  for (final arg in args) {
    if (arg == '--xiaomi' || arg == '--engine=xiaomi') {
      return true;
    }
    if (arg == '--sine' || arg == '--engine=sine') {
      return false;
    }
  }

  return false;
}
