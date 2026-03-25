part of 'package:tts_flow_dart/src/service/tts_flow.dart';

final class _TtsFlowState {
  _ServiceLifecycle lifecycle = _ServiceLifecycle.created;
  _QueueActivity queueActivity = _QueueActivity.idle;
  _QueueMode queueMode = _QueueMode.running;
  SynthesisControl? activeControl;
  final List<TtsChunk> pauseBuffer = <TtsChunk>[];
  int pauseBufferBytes = 0;

  bool get isInitialized => lifecycle == _ServiceLifecycle.initialized;
  bool get isDisposed => lifecycle == _ServiceLifecycle.disposed;
  bool get isPaused => queueMode == _QueueMode.paused;
  bool get isHalted => queueMode == _QueueMode.halted;

  void clearPauseBuffer() {
    pauseBuffer.clear();
    pauseBufferBytes = 0;
  }
}

enum _ServiceLifecycle {
  created,
  initialized,
  disposed,
}

enum _QueueActivity {
  idle,
  processing,
}

enum _QueueMode {
  running,
  paused,
  halted,
}
