import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:tts_flow_dart/tts_flow_dart.dart';
import 'package:tts_flow_flutter/tts_flow_flutter.dart';
import 'package:tts_flow_mimo/tts_flow_mimo.dart';
import 'package:tts_flow_gemini/tts_flow_gemini.dart';
import 'package:url_launcher/url_launcher.dart';

import 'edge_example_tts_engine.dart';
import 'example_source_selector.dart';
import 'example_ui.dart';

part 'tts_flow_example_page_recording_output.dart';
part 'tts_flow_example_page_service_factory.dart';
part 'tts_flow_example_page_value_helpers.dart';
part 'tts_flow_example_page_widgets.dart';

const _sampleAudioAsset = 'assets/audio/test_audio_yanfei.wav';

class TtsFlowExamplePage extends StatelessWidget {
  const TtsFlowExamplePage({
    this.geminiApiKey = '',
    this.mimoApiKey = '',
    this.ttsSource = '',
    super.key,
  });

  /// Development-only key supplied with `--dart-define=MIMO_API_KEY=...`.
  ///
  /// Do not ship production credentials in a client application.
  final String mimoApiKey;

  /// Development-only key supplied with `--dart-define=GEMINI_API_KEY=...`.
  final String geminiApiKey;

  /// Optional source selector: `sample`, `mimo`, `gemini`, or `edge`.
  final String ttsSource;

  @override
  Widget build(BuildContext context) => Material(
    child: ExampleSourceSelector(
      mimoApiKey: mimoApiKey,
      geminiApiKey: geminiApiKey,
      ttsSource: ttsSource,
      builder: (context, configuration) =>
          _SpeakerPlaybackPage(configuration: configuration),
    ),
  );
}

class _SpeakerPlaybackPage extends StatefulWidget {
  const _SpeakerPlaybackPage({required this.configuration});

  final ExampleSourceConfiguration configuration;

  @override
  State<_SpeakerPlaybackPage> createState() => _TtsFlowExamplePageState();
}

class _TtsFlowExamplePageState extends State<_SpeakerPlaybackPage> {
  final _log = Logger('TtsFlowExamplePage');
  final JustAudioBackend _backend = JustAudioBackend();
  final _textController = TextEditingController(
    text: 'Hello from TtsFlow. This is playing through JustAudioBackend.',
  );
  final _eventLog = <String>[];

  TtsFlow? _service;
  StreamSubscription<TtsQueueEvent>? _queueSub;
  StreamSubscription<TtsRequestEvent>? _requestSub;
  StreamSubscription<TtsPlaybackPositionEvent>? _playbackPosSub;
  StreamSubscription<Duration>? _playerPosSub;
  StreamSubscription<Duration?>? _playerDurationSub;

  var _isReady = false;
  var _isBusy = false;
  var _isPaused = false;
  var _requestCounter = 0;
  TtsRequestHandle? _playbackRequest;
  var _status = 'Initializing TtsFlow...';

  Duration _backendPos = Duration.zero;
  Duration _playerPos = Duration.zero;
  Duration _playerDuration = Duration.zero;
  String? _outputDirPath;
  String? _outputAudioPath;
  List<TtsVoice> _voices = const <TtsVoice>[];
  String? _selectedVoiceId;
  double _volume = 1.0;
  double _speed = 1.0;
  double _pitch = 1.0;
  double _minVolume = 0.0;
  double _maxVolume = 0.0;
  double _minSpeed = 0.0;
  double _maxSpeed = 0.0;
  double _minPitch = 0.0;
  double _maxPitch = 0.0;

  ExampleTtsSource get _source => widget.configuration.source;

  String get _engineLabel {
    return switch (_source) {
      ExampleTtsSource.gemini => 'Google Gemini Flash TTS (live)',
      ExampleTtsSource.mimo => 'Xiaomi MiMo V2.5 TTS (live)',
      ExampleTtsSource.edge => 'Edge TTS (experimental)',
      ExampleTtsSource.sample => 'Bundled WAV sample',
    };
  }

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
    unawaited(_playerPosSub?.cancel());
    unawaited(_playerDurationSub?.cancel());
    unawaited(_releaseResources(_service));
    _textController.dispose();
    super.dispose();
  }

  Future<void> _releaseResources(TtsFlow? service) async {
    try {
      await service?.dispose();
    } finally {
      // 引擎初始化失败时，输出尚未被 TtsFlow 接管，仍需释放播放器。
      await _backend.dispose();
    }
  }

  Future<void> _initService() async {
    TtsFlow? service;
    try {
      final resources = await _ExampleServiceFactory(
        configuration: widget.configuration,
      ).create(backend: _backend, log: _log);
      service = resources.service;
      if (!mounted) {
        await _releaseResources(service);
        return;
      }
      final engine = resources.engine;
      _outputDirPath = resources.outputDirectoryPath;
      _outputAudioPath = resources.outputAudioPath;

      await service.init();
      if (!mounted) {
        await _releaseResources(service);
        return;
      }
      service.preferredFormat = _source == ExampleTtsSource.edge
          ? TtsAudioFormat.mp3
          : TtsAudioFormat.pcm;

      _minVolume = engine.minVolume;
      _maxVolume = engine.maxVolume;
      _minSpeed = engine.minSpeed;
      _maxSpeed = engine.maxSpeed;
      _minPitch = engine.minPitch;
      _maxPitch = engine.maxPitch;

      _volume = _normalizeControlValue(_volume, _minVolume, _maxVolume);
      _speed = _normalizeControlValue(_speed, _minSpeed, _maxSpeed);
      _pitch = _normalizeControlValue(_pitch, _minPitch, _maxPitch);

      service.volume = _volume;
      service.speed = _speed;
      service.pitch = _pitch;

      final voices = await service.getAvailableVoices();
      final selectedVoiceId = service.voice.voiceId;

      if (!mounted) {
        await _releaseResources(service);
        return;
      }
      _queueSub = service.queueEvents.listen(_onQueueEvent);
      _requestSub = service.requestEvents.listen(_onRequestEvent);
      _playbackPosSub = _backend.playbackPositionEvents.listen((event) {
        if (!mounted) {
          return;
        }
        setState(() {
          _backendPos = event.position;
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
        await _releaseResources(service);
        return;
      }

      _log.info('TtsFlow initialized successfully.');
      setState(() {
        _service = service;
        _isReady = true;
        _voices = voices;
        _selectedVoiceId = selectedVoiceId;
        _status =
            'Ready using $_engineLabel. Tap "Speak" to play it through the device speaker.';
      });
    } catch (error, stackTrace) {
      _log.severe('Failed to initialize TtsFlow.', error, stackTrace);
      await _releaseResources(service);
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
      'queue event type=${event.type.name} len=${event.queueLength} req=${event.requestKey ?? '-'}',
    );
    _pushEvent(
      'queue ${event.type.name} len=${event.queueLength} req=${event.requestKey ?? '-'}',
    );
  }

  void _onRequestEvent(TtsRequestEvent event) {
    _log.fine(
      'request event type=${event.type.name} req=${event.requestKey} playback=${event.playbackId ?? '-'}',
    );
    _pushEvent(
      'request ${event.type.name} req=${event.requestKey} playback=${event.playbackId ?? '-'}',
    );
    if (event.requestKey == _playbackRequest?.requestKey &&
        (event.type == TtsRequestEventType.requestPlaybackCompleted ||
            event.type == TtsRequestEventType.requestPlaybackFailed ||
            event.type == TtsRequestEventType.requestPlaybackStopped ||
            event.type == TtsRequestEventType.requestSynthesisStopped)) {
      _playbackRequest = null;
    }
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

    final utteranceId = 'flutter-example-${++_requestCounter}';
    final request = service.speak(text, utteranceId: utteranceId);
    _playbackRequest = request;
    _log.info(
      'Starting speech request ${request.requestKey} with ${text.length} chars.',
    );

    try {
      final chunks = await request.chunks.toList();
      if (!mounted) {
        return;
      }
      _log.info(
        'Finished request ${request.requestKey} with ${chunks.length} chunks.',
      );
      setState(() {
        _status =
            'Finished request ${request.requestKey}. Engine emitted ${chunks.length} chunks.';
      });
    } catch (error, stackTrace) {
      _log.severe(
        'Speak failed for request ${request.requestKey}.',
        error,
        stackTrace,
      );
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
    final request = _playbackRequest;
    // 先取消生产，避免关闭播放器期间仍有新分片写入已停止的输出。
    await request?.stopSynthesis();
    if (request?.hasActivePlayback ?? false) {
      await request!.stopPlayback();
    }
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

    final service = _service;
    final request = _playbackRequest;
    if (service == null || request == null || !request.hasActivePlayback) {
      return;
    }
    await request.pausePlayback();
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

    final service = _service;
    final request = _playbackRequest;
    if (service == null || request == null || !request.hasActivePlayback) {
      return;
    }
    await request.resumePlayback();
    if (!mounted) {
      return;
    }
    setState(() {
      _isPaused = false;
      _status = 'Playback resumed.';
    });
  }

  Future<void> _openTempOutputDir() async {
    final dirPath = _outputAudioPath;
    if (dirPath == null || dirPath.isEmpty) {
      setState(() {
        _status = 'Temporary output directory is not available.';
      });
      return;
    }

    final normalized = dirPath.replaceAll('\\', '/');
    final uri = Uri.parse('file:///$normalized');
    final opened = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!mounted) {
      return;
    }

    setState(() {
      _status = opened
          ? 'Opened temporary output directory.'
          : 'Unable to open temporary output directory.';
    });
  }

  void _onVoiceChanged(String? voiceId) {
    if (voiceId == null) {
      return;
    }

    final service = _service;
    final selectedVoice = _voices
        .where((voice) => voice.voiceId == voiceId)
        .cast<TtsVoice?>()
        .firstOrNull;

    if (selectedVoice == null) {
      return;
    }

    if (service != null) {
      service.voice = selectedVoice;
    }

    setState(() {
      _selectedVoiceId = voiceId;
      _status =
          'Selected voice: ${selectedVoice.displayName ?? selectedVoice.voiceId}';
    });
  }

  void _onVolumeChanged(double value) {
    _service?.volume = value;
    setState(() {
      _volume = value;
    });
  }

  void _onSpeedChanged(double value) {
    _service?.speed = value;
    setState(() {
      _speed = value;
    });
  }

  void _onPitchChanged(double value) {
    _service?.pitch = value;
    setState(() {
      _pitch = value;
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
    final theme = Theme.of(context);
    final textPanel = ExampleSection(
      title: 'Text to speech',
      icon: Icons.notes_rounded,
      trailing: Text(
        _isReady ? 'Ready' : 'Preparing…',
        style: theme.textTheme.labelMedium?.copyWith(
          color: _isReady
              ? theme.colorScheme.primary
              : theme.colorScheme.onSurfaceVariant,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _SourceNotice(source: _source),
          const SizedBox(height: 20),
          TextField(
            controller: _textController,
            minLines: 6,
            maxLines: 9,
            style: theme.textTheme.bodyLarge?.copyWith(height: 1.7),
            decoration: const InputDecoration(
              labelText: 'Text to synthesize',
              alignLabelWithHint: true,
              hintText: 'Write something you would like to hear…',
            ),
          ),
          const SizedBox(height: 20),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              FilledButton.icon(
                onPressed: (_isReady && !_isBusy) ? _speak : null,
                icon: const Icon(Icons.volume_up_rounded, size: 20),
                label: const Text('Speak'),
              ),
              OutlinedButton.icon(
                onPressed: _isReady
                    ? (_isPaused ? _resumePlayback : _pausePlayback)
                    : null,
                icon: Icon(
                  _isPaused ? Icons.play_arrow_rounded : Icons.pause_rounded,
                  size: 20,
                ),
                label: Text(_isPaused ? 'Resume' : 'Pause'),
              ),
              OutlinedButton.icon(
                onPressed: _isReady ? _stopCurrent : null,
                icon: const Icon(Icons.stop_rounded, size: 20),
                label: const Text('Stop Current'),
              ),
            ],
          ),
        ],
      ),
    );
    final voicePanel = _VoiceAndAudioControls(
      isReady: _isReady,
      voices: _voices,
      selectedVoiceId: _selectedVoiceId,
      voiceLabel: _voiceLabel,
      onVoiceChanged: _onVoiceChanged,
      volume: _volume,
      minVolume: _minVolume,
      maxVolume: _maxVolume,
      onVolumeChanged: _onVolumeChanged,
      speed: _speed,
      minSpeed: _minSpeed,
      maxSpeed: _maxSpeed,
      onSpeedChanged: _onSpeedChanged,
      pitch: _pitch,
      minPitch: _minPitch,
      maxPitch: _maxPitch,
      onPitchChanged: _onPitchChanged,
      supportsControl: _supportsControl,
      sliderValue: _sliderValue,
      sliderDivisions: _sliderDivisions,
    );
    final outputPanel = ExampleSection(
      title: 'Session & output',
      icon: Icons.audio_file_outlined,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(_engineLabel, style: theme.textTheme.labelLarge),
          const SizedBox(height: 8),
          Text(_status, style: theme.textTheme.bodySmall),
          const SizedBox(height: 16),
          Divider(height: 1, color: theme.colorScheme.outlineVariant),
          const SizedBox(height: 16),
          SelectableText(
            'Audio output: ${_outputAudioPath ?? 'resolving...'}',
            style: theme.textTheme.bodySmall?.copyWith(
              fontFamily: 'monospace',
              fontSize: 11,
            ),
          ),
          const SizedBox(height: 12),
          TextButton.icon(
            onPressed: _outputDirPath == null ? null : _openTempOutputDir,
            icon: const Icon(Icons.folder_open_rounded, size: 18),
            label: const Text('Open Temp Dir'),
          ),
        ],
      ),
    );
    final monitorPanel = ExampleSection(
      title: 'Playback monitor',
      icon: Icons.equalizer_rounded,
      child: Column(
        children: [
          _PlaybackTimeline(
            label: 'PlaybackTimelineReporter',
            position: _backendPos,
            duration: _playerDuration,
          ),
          const SizedBox(height: 24),
          _PlaybackTimeline(
            label: 'just_audio player.positionStream',
            position: _playerPos,
            duration: _playerDuration,
          ),
        ],
      ),
    );
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(24, 8, 24, 32),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 1232),
          child: Column(
            children: [
              LayoutBuilder(
                builder: (context, constraints) {
                  if (constraints.maxWidth < 980) {
                    return Column(
                      children: [
                        textPanel,
                        const SizedBox(height: 20),
                        voicePanel,
                        const SizedBox(height: 20),
                        monitorPanel,
                        const SizedBox(height: 20),
                        outputPanel,
                      ],
                    );
                  }
                  return Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        flex: 3,
                        child: Column(
                          children: [
                            textPanel,
                            const SizedBox(height: 20),
                            outputPanel,
                          ],
                        ),
                      ),
                      const SizedBox(width: 20),
                      Expanded(
                        flex: 2,
                        child: Column(
                          children: [
                            voicePanel,
                            const SizedBox(height: 20),
                            monitorPanel,
                          ],
                        ),
                      ),
                    ],
                  );
                },
              ),
              const SizedBox(height: 20),
              ExampleSection(
                title: 'Events',
                icon: Icons.terminal_rounded,
                trailing: Text(
                  '${_eventLog.length} events',
                  style: theme.textTheme.bodySmall,
                ),
                child: SizedBox(
                  height: 180,
                  child: _eventLog.isEmpty
                      ? Center(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                Icons.waves_rounded,
                                color: theme.colorScheme.outline,
                                size: 28,
                              ),
                              const SizedBox(height: 8),
                              Text(
                                'Playback events will appear here.',
                                style: theme.textTheme.bodySmall,
                              ),
                            ],
                          ),
                        )
                      : ListView.separated(
                          itemCount: _eventLog.length,
                          separatorBuilder: (_, _) => const SizedBox(height: 8),
                          itemBuilder: (context, index) => Text(
                            _eventLog[index],
                            style: theme.textTheme.bodySmall?.copyWith(
                              fontFamily: 'monospace',
                              fontSize: 11,
                            ),
                          ),
                        ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
