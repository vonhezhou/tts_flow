import 'dart:async';

import 'package:flutter/material.dart';
import 'package:tts_flow_dart/tts_flow_dart.dart';
import 'package:tts_flow_flutter/tts_flow_flutter.dart';

import 'example_ui.dart';
import 'package:tts_flow_flutter_example/reader/demo_sentence_cue_engine.dart';
import 'package:tts_flow_flutter_example/reader/reading_session.dart';

const _passage =
    'The rain stopped before sunrise. A small bird landed on the window. '
    'The city slowly began another quiet morning.';

class ReaderDemoPage extends StatefulWidget {
  const ReaderDemoPage({super.key});

  @override
  State<ReaderDemoPage> createState() => _ReaderDemoPageState();
}

class _ReaderDemoPageState extends State<ReaderDemoPage> {
  final JustAudioBackend _backend = JustAudioBackend();
  TtsFlow? _flow;
  ReadingSession? _readingSession;
  var _isReady = false;
  var _status = 'Preparing reader demo…';

  @override
  void initState() {
    super.initState();
    unawaited(_initialize());
  }

  @override
  void dispose() {
    unawaited(_readingSession?.dispose());
    unawaited(_flow?.dispose());
    super.dispose();
  }

  Future<void> _initialize() async {
    final speakerOutput = SpeakerOutput(backend: _backend);
    final flow = TtsFlow(
      engine: DemoSentenceCueEngine(),
      defaultOutput: speakerOutput,
    );
    await flow.init();
    final session = ReadingSession(
      flow: flow,
      timelineReporter: speakerOutput.timelineReporter,
    );
    if (!mounted) {
      await session.dispose();
      await flow.dispose();
      return;
    }
    setState(() {
      _flow = flow;
      _readingSession = session;
      _isReady = true;
      _status = session.supportsPreciseSentenceTiming
          ? 'Ready: sentence timing is supplied by the demo provider.'
          : 'Ready: this backend has no playback timeline.';
    });
  }

  Future<void> _startReading() async {
    final session = _readingSession;
    if (session == null) {
      return;
    }
    await session.start(_passage);
    if (!mounted) {
      return;
    }
    setState(() {
      _status = 'Reading. The highlight changes only when a sentence changes.';
    });
  }

  Future<void> _stopReading() async {
    await _readingSession?.stop();
    if (!mounted) {
      return;
    }
    setState(() {
      _status = 'Reading stopped.';
    });
  }

  @override
  Widget build(BuildContext context) {
    final session = _readingSession;
    final theme = Theme.of(context);
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(24, 24, 24, 40),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 960),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Follow every sentence.',
                style: theme.textTheme.headlineSmall,
              ),
              const SizedBox(height: 8),
              Text(
                'A reading demo with playback-synchronized highlighting.',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 28),
              ExampleSection(
                title: 'Morning, after the rain',
                icon: Icons.menu_book_rounded,
                child: session == null
                    ? Padding(
                        padding: const EdgeInsets.symmetric(vertical: 48),
                        child: Center(child: Text(_status)),
                      )
                    : Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const SizedBox(height: 12),
                          ValueListenableBuilder<ReadingHighlight?>(
                            valueListenable: session.highlight,
                            builder: (context, highlight, _) => Text.rich(
                              _passageSpan(context, highlight),
                              style: theme.textTheme.headlineSmall?.copyWith(
                                height: 1.9,
                                fontWeight: FontWeight.w400,
                                letterSpacing: 0,
                              ),
                            ),
                          ),
                          const SizedBox(height: 32),
                          Divider(color: theme.colorScheme.outlineVariant),
                          const SizedBox(height: 16),
                          Wrap(
                            spacing: 12,
                            runSpacing: 12,
                            children: [
                              FilledButton.icon(
                                onPressed: _isReady ? _startReading : null,
                                icon: const Icon(Icons.play_arrow_rounded),
                                label: const Text('Read passage'),
                              ),
                              OutlinedButton.icon(
                                onPressed: _isReady ? _stopReading : null,
                                icon: const Icon(Icons.stop_rounded),
                                label: const Text('Stop'),
                              ),
                            ],
                          ),
                        ],
                      ),
              ),
              const SizedBox(height: 20),
              ExampleSection(
                title: 'Reading status',
                icon: Icons.schedule_rounded,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(_status, style: theme.textTheme.bodyMedium),
                    const SizedBox(height: 8),
                    Text(
                      'The demo engine emits sentence cues. Providers without '
                      'timing fall back to highlighting the request group.',
                      style: theme.textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  TextSpan _passageSpan(BuildContext context, ReadingHighlight? highlight) {
    if (highlight == null) {
      return const TextSpan(text: _passage);
    }
    final activeStyle = TextStyle(
      backgroundColor: Theme.of(
        context,
      ).colorScheme.primary.withValues(alpha: 0.18),
      color: Theme.of(context).colorScheme.primary,
      fontWeight: FontWeight.w700,
    );
    return TextSpan(
      children: [
        TextSpan(text: _passage.substring(0, highlight.startOffset)),
        TextSpan(
          text: _passage.substring(highlight.startOffset, highlight.endOffset),
          style: activeStyle,
        ),
        TextSpan(text: _passage.substring(highlight.endOffset)),
      ],
    );
  }
}
