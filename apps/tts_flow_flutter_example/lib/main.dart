import 'package:flutter/material.dart';
import 'package:logging/logging.dart';
import 'package:logging_appenders/logging_appenders.dart';
import 'package:tts_flow_flutter_example/reader_demo_page.dart';
import 'package:tts_flow_flutter_example/tts_flow_example_page.dart';

const _mimoApiKey = String.fromEnvironment('MIMO_API_KEY');
const _ttsSource = String.fromEnvironment('TTS_SOURCE');
const _geminiApiKey = String.fromEnvironment('GEMINI_API_KEY');

void main(List<String> args) {
  Logger.root.clearListeners();
  Logger.root.level = Level.ALL;
  PrintAppender(formatter: ColorFormatter()).attachToLogger(Logger.root);

  runApp(
    const MyApp(
      mimoApiKey: _mimoApiKey,
      geminiApiKey: _geminiApiKey,
      ttsSource: _ttsSource,
    ),
  );
}

class MyApp extends StatelessWidget {
  const MyApp({
    this.geminiApiKey = '',
    required this.mimoApiKey,
    required this.ttsSource,
    super.key,
  });

  final String mimoApiKey;
  final String geminiApiKey;
  final String ttsSource;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'TtsFlow Speaker Example',
      theme: ThemeData.dark(),
      home: _ExampleHome(
        geminiApiKey: geminiApiKey,
        mimoApiKey: mimoApiKey,
        ttsSource: ttsSource,
      ),
    );
  }
}

class _ExampleHome extends StatelessWidget {
  const _ExampleHome({
    required this.geminiApiKey,
    required this.mimoApiKey,
    required this.ttsSource,
  });

  final String mimoApiKey;
  final String geminiApiKey;
  final String ttsSource;

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
        body: TabBarView(
          children: [
            TtsFlowExamplePage(
              geminiApiKey: geminiApiKey,
              mimoApiKey: mimoApiKey,
              ttsSource: ttsSource,
            ),
            const ReaderDemoPage(),
          ],
        ),
      ),
    );
  }
}
