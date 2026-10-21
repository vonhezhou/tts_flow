import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:tts_flow_dart/tts_flow_dart.dart';
import 'package:tts_flow_azure/tts_flow_azure.dart';
import 'package:tts_flow_flutter/tts_flow_flutter.dart';
import 'package:tts_flow_mimo/tts_flow_mimo.dart';
import 'package:tts_flow_gemini/tts_flow_gemini.dart';
import 'package:url_launcher/url_launcher.dart';

part 'tts_flow_example_page_recording_output.dart';
part 'tts_flow_example_page_service_factory.dart';
part 'tts_flow_example_page_value_helpers.dart';
part 'tts_flow_example_page_widgets.dart';

const _sampleAudioAsset = 'assets/audio/test_audio_yanfei.wav';

class TtsFlowExamplePage extends StatefulWidget {
  const TtsFlowExamplePage({
    this.geminiApiKey = '',
    this.mimoApiKey = '',
    this.azureSpeechKey = '',
    this.azureSpeechRegion = '',
    this.ttsSource = '',
    super.key,
  });

  /// Development-only key supplied with `--dart-define=MIMO_API_KEY=...`.
  ///
  /// Do not ship production credentials in a client application.
  final String mimoApiKey;

  /// Development-only key supplied with `--dart-define=GEMINI_API_KEY=...`.
  final String geminiApiKey;

  /// Development-only Azure credentials supplied with
  /// `--dart-define=AZURE_SPEECH_KEY=...` and
  /// `--dart-define=AZURE_SPEECH_REGION=...`.
  final String azureSpeechKey;
  final String azureSpeechRegion;

  /// Optional live source selector: `mimo`, `azure`, or `gemini`.
  final String ttsSource;

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

  String get _requestedSource => widget.ttsSource.trim().toLowerCase();

  bool get _usesMimo =>
      (_requestedSource.isEmpty || _requestedSource == 'mimo') &&
      widget.mimoApiKey.trim().isNotEmpty;

  bool get _usesAzure =>
      _requestedSource == 'azure' &&
      widget.azureSpeechKey.trim().isNotEmpty &&
      widget.azureSpeechRegion.trim().isNotEmpty;

  bool get _usesGemini =>
      _requestedSource == 'gemini' && widget.geminiApiKey.trim().isNotEmpty;

  bool get _hasAzureConfiguration =>
      widget.azureSpeechKey.trim().isNotEmpty &&
      widget.azureSpeechRegion.trim().isNotEmpty;

  String get _engineLabel {
    if (_usesGemini) return 'Google Gemini Flash TTS (live)';
    if (_requestedSource == 'gemini') {
      return 'Gemini TTS (configuration needed)';
    }
    if (_usesAzure) return 'Azure AI Speech (live)';
    if (_usesMimo) return 'Xiaomi MiMo V2.5 TTS (live)';
    if (_requestedSource == 'azure' && !_hasAzureConfiguration) {
      return 'Azure AI Speech (configuration needed)';
    }
    return 'Bundled WAV sample';
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
    unawaited(_service?.dispose());
    _textController.dispose();
    super.dispose();
  }

  Future<void> _initService() async {
    TtsFlow? service;
    try {
      final resources = await _ExampleServiceFactory(
        usesGemini: _usesGemini,
        geminiApiKey: widget.geminiApiKey,
        usesMimo: _usesMimo,
        usesAzure: _usesAzure,
        mimoApiKey: widget.mimoApiKey,
        azureSpeechKey: widget.azureSpeechKey,
        azureSpeechRegion: widget.azureSpeechRegion,
      ).create(backend: _backend, log: _log);
      service = resources.service;
      final engine = resources.engine;
      _outputDirPath = resources.outputDirectoryPath;
      _outputAudioPath = resources.outputAudioPath;

      await service.init();
      service.preferredFormat = _usesAzure
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
        await service.dispose();
        return;
      }

      _log.info('TtsFlow initialized successfully.');
      setState(() {
        _service = service;
        _isReady = true;
        _voices = voices;
        _selectedVoiceId = selectedVoiceId;
        _status =
            'Ready using $_engineLabel. Tap "Speak" to play it through the device speaker. Auxiliary audio: $_outputAudioPath';
      });
    } catch (error, stackTrace) {
      _log.severe('Failed to initialize TtsFlow.', error, stackTrace);
      await service?.dispose();
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
    if (request?.hasActivePlayback ?? false) {
      await request!.stopPlayback();
    }
    await request?.stopSynthesis();
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
    return Scaffold(
      appBar: AppBar(
        title: Text('TtsFlow + JustAudioBackend ($_engineLabel)'),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
      ),
      body: Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _SourceNotice(
              usesGemini: _usesGemini,
              usesMimo: _usesMimo,
              usesAzure: _usesAzure,
              requestedSource: _requestedSource,
              hasAzureConfiguration: _hasAzureConfiguration,
            ),
            const SizedBox(height: 12),
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
            _VoiceAndAudioControls(
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
                OutlinedButton.icon(
                  onPressed: _outputDirPath == null ? null : _openTempOutputDir,
                  icon: const Icon(Icons.folder_open),
                  label: const Text('Open Temp Dir'),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Text(_status, style: Theme.of(context).textTheme.bodyMedium),
            const SizedBox(height: 6),
            SelectableText(
              'Audio output: ${_outputAudioPath ?? 'resolving...'}',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            Text(
              'PlaybackTimelineReporter',
              style: Theme.of(context).textTheme.titleSmall,
            ),
            LinearProgressIndicator(
              value: _progressValue(_backendPos, _playerDuration),
            ),
            const SizedBox(height: 4),
            Text(
              '${_formatDuration(_backendPos)} / ${_formatDuration(_playerDuration)}',
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
