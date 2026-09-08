import 'package:flutter/material.dart';
import 'package:logging/logging.dart';
import 'package:logging_appenders/logging_appenders.dart';
import 'package:tts_flow_flutter_example/reader_demo_page.dart';
import 'package:tts_flow_flutter_example/tts_flow_example_page.dart';

void main(List<String> args) {
  Logger.root.clearListeners();
  Logger.root.level = Level.ALL;
  PrintAppender(formatter: ColorFormatter()).attachToLogger(Logger.root);

  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'TtsFlow Speaker Example',
      theme: ThemeData.dark(),
      home: const _ExampleHome(),
    );
  }
}

class _ExampleHome extends StatelessWidget {
  const _ExampleHome();

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('TtsFlow examples'),
          bottom: const TabBar(
            tabs: [
              Tab(text: 'Speaker'),
              Tab(text: 'Reader'),
            ],
          ),
        ),
        body: const TabBarView(
          children: [TtsFlowExamplePage(), ReaderDemoPage()],
        ),
      ),
    );
  }
}
