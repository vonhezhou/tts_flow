import 'dart:io';

import 'package:flutter/material.dart';
import 'package:logging/logging.dart';
import 'package:logging_appenders/logging_appenders.dart';
import 'package:tts_flow_flutter_example/reader_demo_page.dart';
import 'package:tts_flow_flutter_example/tts_flow_example_page.dart';

import 'example_ui.dart';

const _mimoApiKey = String.fromEnvironment('MIMO_API_KEY');
const _ttsSource = String.fromEnvironment('TTS_SOURCE');
const _geminiApiKey = String.fromEnvironment('GEMINI_API_KEY');

void main(List<String> args) {
  Logger.root.clearListeners();
  Logger.root.level = Level.ALL;
  PrintAppender(formatter: ColorFormatter()).attachToLogger(Logger.root);

  runApp(
    MyApp(
      mimoApiKey: _environmentValue(_mimoApiKey, 'MIMO_API_KEY'),
      geminiApiKey: _environmentValue(_geminiApiKey, 'GEMINI_API_KEY'),
      ttsSource: _environmentValue(_ttsSource, 'TTS_SOURCE'),
    ),
  );
}

String _environmentValue(String defined, String name) =>
    defined.trim().isNotEmpty
    ? defined.trim()
    : Platform.environment[name] ?? '';

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
      debugShowCheckedModeBanner: false,
      title: 'TtsFlow Speaker Example',
      theme: exampleTheme(),
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
          toolbarHeight: 80,
          title: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: Theme.of(
                    context,
                  ).colorScheme.primary.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Icon(
                  Icons.graphic_eq_rounded,
                  color: Theme.of(context).colorScheme.primary,
                ),
              ),
              const SizedBox(width: 12),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'TtsFlow',
                    style: Theme.of(context).textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  Text(
                    'Streaming audio workspace',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
            ],
          ),
          bottom: const PreferredSize(
            preferredSize: Size.fromHeight(56),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Padding(
                padding: EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: TabBar(
                  isScrollable: true,
                  tabAlignment: TabAlignment.start,
                  tabs: [
                    Tab(
                      child: Row(
                        children: [
                          Icon(Icons.mic_none_rounded, size: 18),
                          SizedBox(width: 8),
                          Text('Speaker'),
                        ],
                      ),
                    ),
                    Tab(
                      child: Row(
                        children: [
                          Icon(Icons.menu_book_rounded, size: 18),
                          SizedBox(width: 8),
                          Text('Reader'),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
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
