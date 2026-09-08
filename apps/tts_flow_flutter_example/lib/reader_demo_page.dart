import 'dart:async';

import 'package:flutter/material.dart';
import 'package:tts_flow_dart/tts_flow_dart.dart';
import 'package:tts_flow_flutter/tts_flow_flutter.dart';
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
    return Scaffold(
      appBar: AppBar(title: const Text('Reader timing demo')),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: session == null
            ? Center(child: Text(_status))
            : Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(_status),
                  const SizedBox(height: 24),
                  ValueListenableBuilder<ReadingHighlight?>(
                    valueListenable: session.highlight,
                    builder: (context, highlight, _) {
                      return Text.rich(
                        _passageSpan(context, highlight),
                        style: Theme.of(context).textTheme.headlineSmall,
                      );
                    },
                  ),
                  const SizedBox(height: 16),
                  Text(
                    'The demo engine emits sentence cues. Providers without '
                    'timing fall back to highlighting the request group.',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  const Spacer(),
                  Wrap(
                    spacing: 12,
                    children: [
                      FilledButton.icon(
                        onPressed: _isReady ? _startReading : null,
                        icon: const Icon(Icons.play_arrow),
                        label: const Text('Read passage'),
                      ),
                      OutlinedButton.icon(
                        onPressed: _isReady ? _stopReading : null,
                        icon: const Icon(Icons.stop),
                        label: const Text('Stop'),
                      ),
                    ],
                  ),
                ],
              ),
      ),
    );
  }

  TextSpan _passageSpan(BuildContext context, ReadingHighlight? highlight) {
    if (highlight == null) {
      return const TextSpan(text: _passage);
    }
    final activeStyle = TextStyle(
      backgroundColor: Theme.of(context).colorScheme.primaryContainer,
      color: Theme.of(context).colorScheme.onPrimaryContainer,
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
