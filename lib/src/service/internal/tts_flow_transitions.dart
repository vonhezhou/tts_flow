part of 'package:tts_flow_dart/src/service/tts_flow.dart';

extension _TtsFlowStateTransitions on _TtsFlowState {
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
