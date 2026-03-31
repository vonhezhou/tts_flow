import 'dart:async';

import 'package:flutter/material.dart';
import 'package:logging/logging.dart';
import 'package:tts_flow_dart/tts_flow_dart.dart';
import 'package:tts_flow_flutter/tts_flow_flutter.dart';
import 'package:tts_flow_flutter_example/xiaomi_tts.dart';

const bool _useXiaomiTts = true;
const String _xiaomiApiKey = String.fromEnvironment('XIAOMI_MIMO_API_KEY');

class TtsFlowExamplePage extends StatefulWidget {
  const TtsFlowExamplePage({super.key});

  @override
  State<TtsFlowExamplePage> createState() => _TtsFlowExamplePageState();
}

class _TtsFlowExamplePageState extends State<TtsFlowExamplePage> {
  final _log = Logger('TtsFlowExamplePage');
  final _textController = TextEditingController(
    text: 'Hello from TtsFlow. This is playing through JustAudioBackend.',
  );
  final _eventLog = <String>[];

  TtsFlow? _service;
  StreamSubscription<TtsQueueEvent>? _queueSub;
  StreamSubscription<TtsRequestEvent>? _requestSub;

  var _isReady = false;
  var _isBusy = false;
  var _requestCounter = 0;
  var _status = 'Initializing TtsFlow...';

  String get _engineLabel => _useXiaomiTts ? 'Xiaomi Mimo' : 'Sine';

  @override
  void initState() {
    super.initState();
    _log.info('Page initialized. Starting TtsFlow service setup.');
    unawaited(_initService());
  }

  @override
  void dispose() {
    _log.info('Disposing page and TtsFlow service.');
    unawaited(_queueSub?.cancel());
    unawaited(_requestSub?.cancel());
    unawaited(_service?.dispose());
    _textController.dispose();
    super.dispose();
  }

  Future<void> _initService() async {
    final engine = _useXiaomiTts
        ? XiaomiTts.fromClientConfig(
            config: OpenAiClientConfig(
              apiKey: _xiaomiApiKey,
              endpoint: XiaomiTts.xiaomiEndpoint,
              model: XiaomiTts.xiaomiModel,
            ),
          )
        : SineTtsEngine(
            engineId: 'flutter-sine-engine',
            supportsStreaming: true,
            chunkCount: 6,
            chunkDelay: const Duration(milliseconds: 20),
          );

    final service = TtsFlow(
      engine: engine,
      defaultOutput: MulticastOutput(
        outputs: [
          SpeakerOutput(backend: JustAudioBackend()),
          Decoder(
            outputId: 'decoder',
            output: WavFileOutput("D:/Codes/flutter_uni_tts/test_out.wav"),
            pcmFormat: const PcmDescriptor(
              sampleRateHz: 16000, // 强制 16kHz
              channels: 1, // 强制单声道
              bitsPerSample: 16, // 强制 16 位
            ),
          ),
        ],
      ),
    );

    try {
      await service.init();
      service.preferredFormat = _useXiaomiTts
          ? TtsAudioFormat.mp3
          : TtsAudioFormat.pcm;

      _queueSub = service.queueEvents.listen(_onQueueEvent);
      _requestSub = service.requestEvents.listen(_onRequestEvent);

      if (!mounted) {
        await service.dispose();
        return;
      }

      _log.info('TtsFlow initialized successfully.');
      setState(() {
        _service = service;
        _isReady = true;
        _status =
            'Ready using $_engineLabel engine. Tap "Speak" to play through the device speaker.';
      });
    } catch (error, stackTrace) {
      _log.severe('Failed to initialize TtsFlow.', error, stackTrace);
      await service.dispose();
      if (!mounted) {
        return;
      }
      setState(() {
        _status = 'Failed to initialize TtsFlow: $error';
      });
    }
  }

  void _onQueueEvent(TtsQueueEvent event) {
    _log.fine(
      'queue event type=${event.type.name} len=${event.queueLength} req=${event.requestId ?? '-'}',
    );
    _pushEvent(
      'queue ${event.type.name} len=${event.queueLength} req=${event.requestId ?? '-'}',
    );
  }

  void _onRequestEvent(TtsRequestEvent event) {
    _log.fine(
      'request event type=${event.type.name} req=${event.requestId} playback=${event.playbackId ?? '-'}',
    );
    _pushEvent(
      'request ${event.type.name} req=${event.requestId} playback=${event.playbackId ?? '-'}',
    );
  }

  Future<void> _speak() async {
    final service = _service;
    final text = _textController.text.trim();
    if (!_isReady || service == null || text.isEmpty || _isBusy) {
      return;
    }

    setState(() {
      _isBusy = true;
      _status = 'Synthesizing and playing...';
    });

    final requestId = 'flutter-example-${++_requestCounter}';
    _log.info('Starting speech request $requestId with ${text.length} chars.');

    try {
      final chunks = await service.speak(requestId, text).toList();
      if (!mounted) {
        return;
      }
      _log.info('Finished request $requestId with ${chunks.length} chunks.');
      setState(() {
        _status =
            'Finished request $requestId. Engine emitted ${chunks.length} chunks.';
      });
    } catch (error, stackTrace) {
      _log.severe('Speak failed for request $requestId.', error, stackTrace);
      if (!mounted) {
        return;
      }
      setState(() {
        _status = 'Speak failed: $error';
      });
    } finally {
      if (mounted) {
        setState(() {
          _isBusy = false;
        });
      }
    }
  }

  Future<void> _stopCurrent() async {
    final service = _service;
    if (!_isReady || service == null) {
      return;
    }
    _log.info('Stopping current request.');
    await service.stopCurrent();
    if (!mounted) {
      return;
    }
    setState(() {
      _status = 'Current request stopped.';
      _isBusy = false;
    });
  }

  void _pushEvent(String value) {
    if (!mounted) {
      return;
    }
    setState(() {
      _eventLog.insert(0, value);
      if (_eventLog.length > 40) {
        _eventLog.removeRange(40, _eventLog.length);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('TtsFlow + JustAudioBackend ($_engineLabel)'),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: _textController,
              minLines: 2,
              maxLines: 4,
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                labelText: 'Text to synthesize',
              ),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                FilledButton.icon(
                  onPressed: (_isReady && !_isBusy) ? _speak : null,
                  icon: const Icon(Icons.volume_up),
                  label: const Text('Speak'),
                ),
                OutlinedButton.icon(
                  onPressed: _isReady ? _stopCurrent : null,
                  icon: const Icon(Icons.stop),
                  label: const Text('Stop Current'),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Text(_status, style: Theme.of(context).textTheme.bodyMedium),
            const SizedBox(height: 12),
            Text('Events', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            Expanded(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  border: Border.all(color: Theme.of(context).dividerColor),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: ListView.builder(
                  padding: const EdgeInsets.all(8),
                  itemCount: _eventLog.length,
                  itemBuilder: (context, index) {
                    return Text(_eventLog[index]);
                  },
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
