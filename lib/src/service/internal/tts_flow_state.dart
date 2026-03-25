part of 'package:tts_flow_dart/src/service/tts_flow.dart';

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

  // paused: new requests are accepted but not processed until resume() is called
  paused,

  // halted: encounters a failure and drop pending requests until speak() is called;
  halted,
}

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

  void markInitialized() {
    lifecycle = _ServiceLifecycle.initialized;
  }

  void markDisposed() {
    clearPauseBuffer();
    activeControl = null;
    queueActivity = _QueueActivity.idle;
    queueMode = _QueueMode.running;
    lifecycle = _ServiceLifecycle.disposed;
  }

  bool tryEnterProcessing() {
    if (queueActivity == _QueueActivity.processing || isDisposed) {
      return false;
    }
    queueActivity = _QueueActivity.processing;
    return true;
  }

  void exitProcessing() {
    queueActivity = _QueueActivity.idle;
  }

  void unhaltOnEnqueue() {
    if (queueMode == _QueueMode.halted) {
      queueMode = _QueueMode.running;
    }
  }

  void pauseQueue() {
    if (queueMode != _QueueMode.halted) {
      queueMode = _QueueMode.paused;
    }
  }

  void resumeQueue() {
    if (queueMode == _QueueMode.paused) {
      queueMode = _QueueMode.running;
    }
  }

  void haltQueue() {
    queueMode = _QueueMode.halted;
  }

  void ensureNotDisposed() {
    if (isDisposed) {
      throw StateError('TtsFlow is disposed.');
    }
  }

  void ensureReady() {
    ensureNotDisposed();
    if (!isInitialized) {
      throw StateError('TtsFlow is not initialized. Call init() first.');
    }
  }
}
