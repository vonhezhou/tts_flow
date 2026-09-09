import 'package:tts_flow_dart/src/core/synthesis_control.dart';

enum ServiceLifecycle { created, initialized, disposed }

enum QueueActivity { idle, processing }

enum QueueMode {
  running,

  // paused: new requests are accepted but not processed until resume() is called
  paused,

  // halted: encounters a failure and drop pending requests until speak() is called;
  halted,
}

final class TtsFlowState {
  ServiceLifecycle lifecycle = ServiceLifecycle.created;
  QueueActivity queueActivity = QueueActivity.idle;
  QueueMode queueMode = QueueMode.running;
  SynthesisControl? activeControl;
  String? activeRequestKey;

  bool get isInitialized => lifecycle == ServiceLifecycle.initialized;
  bool get isDisposed => lifecycle == ServiceLifecycle.disposed;
  bool get isPaused => queueMode == QueueMode.paused;
  bool get isHalted => queueMode == QueueMode.halted;

  void markInitialized() {
    lifecycle = ServiceLifecycle.initialized;
  }

  void markDisposed() {
    activeControl = null;
    activeRequestKey = null;
    queueActivity = QueueActivity.idle;
    queueMode = QueueMode.running;
    lifecycle = ServiceLifecycle.disposed;
  }

  bool tryEnterProcessing() {
    if (queueActivity == QueueActivity.processing || isDisposed) {
      return false;
    }
    queueActivity = QueueActivity.processing;
    return true;
  }

  void exitProcessing() {
    queueActivity = QueueActivity.idle;
  }

  void unhaltOnEnqueue() {
    if (queueMode == QueueMode.halted) {
      queueMode = QueueMode.running;
    }
  }

  void pauseQueue() {
    if (queueMode != QueueMode.halted) {
      queueMode = QueueMode.paused;
    }
  }

  void resumeQueue() {
    if (queueMode == QueueMode.paused) {
      queueMode = QueueMode.running;
    }
  }

  void haltQueue() {
    queueMode = QueueMode.halted;
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
