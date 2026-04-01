import 'dart:async';

import 'package:flutter/material.dart';
import 'package:logging/logging.dart';
import 'package:tts_flow_dart/tts_flow_dart.dart';
import 'package:tts_flow_flutter/tts_flow_flutter.dart';
import 'package:tts_flow_flutter_example/xiaomi_tts.dart';

const String _xiaomiApiKey = String.fromEnvironment('XIAOMI_MIMO_API_KEY');

class TtsFlowExamplePage extends StatefulWidget {
  const TtsFlowExamplePage({required this.useXiaomiTts, super.key});

  final bool useXiaomiTts;

  @override
  State<TtsFlowExamplePage> createState() => _TtsFlowExamplePageState();
}

class _TtsFlowExamplePageState extends State<TtsFlowExamplePage> {
  final _log = Logger('TtsFlowExamplePage');
  final JustAudioBackend _backend = JustAudioBackend();
  final _textController = TextEditingController(
    text: 'Hello from TtsFlow. This is playing through JustAudioBackend.',
  );
  final _eventLog = <String>[];

  TtsFlow? _service;
  StreamSubscription<TtsQueueEvent>? _queueSub;
  StreamSubscription<TtsRequestEvent>? _requestSub;
  StreamSubscription<JustAudioPosEvent>? _playbackPosSub;
  StreamSubscription<JustAudioDurationEvent>? _playbackDurationSub;
  StreamSubscription<Duration>? _playerPosSub;
  StreamSubscription<Duration?>? _playerDurationSub;

  var _isReady = false;
  var _isBusy = false;
  var _isPaused = false;
  var _requestCounter = 0;
  var _status = 'Initializing TtsFlow...';

  Duration _backendPos = Duration.zero;
  Duration _backendDuration = Duration.zero;
  Duration _playerPos = Duration.zero;
  Duration _playerDuration = Duration.zero;

  String get _engineLabel => widget.useXiaomiTts ? 'Xiaomi Mimo' : 'Sine';

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
    unawaited(_playbackPosSub?.cancel());
    unawaited(_playbackDurationSub?.cancel());
    unawaited(_playerPosSub?.cancel());
    unawaited(_playerDurationSub?.cancel());
    unawaited(_service?.dispose());
    _textController.dispose();
    super.dispose();
  }

  Future<void> _initService() async {
    final engine = widget.useXiaomiTts
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
          SpeakerOutput(backend: _backend),
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
      service.preferredFormat = widget.useXiaomiTts
          ? TtsAudioFormat.mp3
          : TtsAudioFormat.pcm;

      _queueSub = service.queueEvents.listen(_onQueueEvent);
      _requestSub = service.requestEvents.listen(_onRequestEvent);
      _playbackPosSub = _backend.playbackPositionStream.listen((event) {
        if (!mounted) {
          return;
        }
        setState(() {
          _backendPos = event.position;
          if (_backendDuration < event.position) {
            _backendDuration = event.position;
          }
        });
      });
      _playbackDurationSub = _backend.playbackDurationStream.listen((event) {
        if (!mounted) {
          return;
        }
        setState(() {
          if (event.duration > _backendDuration) {
            _backendDuration = event.duration;
          }
        });
      });
      _playerPosSub = _backend.player.positionStream.listen((event) {
        if (!mounted) {
          return;
        }
        setState(() {
          _playerPos = event;
          if (_playerDuration < event) {
            _playerDuration = event;
          }
        });
      });
      _playerDurationSub = _backend.player.durationStream.listen((event) {
        if (!mounted || event == null) {
          return;
        }
        setState(() {
          _playerDuration = event;
        });
      });

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
      _isPaused = false;
    });
  }

  Future<void> _pausePlayback() async {
    if (!_isReady) {
      return;
    }

    await _service?.pause();
    if (!mounted) {
      return;
    }
    setState(() {
      _isPaused = true;
      _status = 'Playback paused.';
    });
  }

  Future<void> _resumePlayback() async {
    if (!_isReady) {
      return;
    }

    await _service?.resume();
    if (!mounted) {
      return;
    }
    setState(() {
      _isPaused = false;
      _status = 'Playback resumed.';
    });
  }

  double _progressValue(Duration position, Duration total) {
    final totalMs = total.inMilliseconds;
    if (totalMs <= 0) {
      return 0;
    }
    final ratio = position.inMilliseconds / totalMs;
    return ratio.clamp(0, 1).toDouble();
  }

  String _formatDuration(Duration value) {
    final hours = value.inHours;
    final minutes = value.inMinutes.remainder(60);
    final seconds = value.inSeconds.remainder(60);
    final millis = value.inMilliseconds.remainder(1000);

    if (hours > 0) {
      return '$hours:${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
    }

    return '${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}.${(millis ~/ 10).toString().padLeft(2, '0')}';
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
                OutlinedButton.icon(
                  onPressed: _isReady
                      ? (_isPaused ? _resumePlayback : _pausePlayback)
                      : null,
                  icon: Icon(_isPaused ? Icons.play_arrow : Icons.pause),
                  label: Text(_isPaused ? 'Resume' : 'Pause'),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Text(_status, style: Theme.of(context).textTheme.bodyMedium),
            const SizedBox(height: 12),
            Text(
              'Backend playbackPositionStream',
              style: Theme.of(context).textTheme.titleSmall,
            ),
            LinearProgressIndicator(
              value: _progressValue(_backendPos, _backendDuration),
            ),
            const SizedBox(height: 4),
            Text(
              '${_formatDuration(_backendPos)} / ${_formatDuration(_backendDuration)}',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            Text(
              'just_audio player.positionStream',
              style: Theme.of(context).textTheme.titleSmall,
            ),
            LinearProgressIndicator(
              value: _progressValue(_playerPos, _playerDuration),
            ),
            const SizedBox(height: 4),
            Text(
              '${_formatDuration(_playerPos)} / ${_formatDuration(_playerDuration)}',
              style: Theme.of(context).textTheme.bodySmall,
            ),
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
