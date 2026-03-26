import 'dart:typed_data';

import 'package:tts_flow_dart/tts_flow_dart.dart';

sealed class AudioArtifact {
  const AudioArtifact({
    required this.requestId,
    required this.audioSpec,
  });

  final String requestId;
  final TtsAudioSpec audioSpec;
}

final class InMemoryAudioArtifact extends AudioArtifact {
  const InMemoryAudioArtifact({
    required super.requestId,
    required super.audioSpec,
    required this.audioBytes,
    required this.totalBytes,
  });

  final Uint8List audioBytes;
  final int totalBytes;
}

final class FileAudioArtifact extends AudioArtifact {
  const FileAudioArtifact({
    required super.requestId,
    required super.audioSpec,
    required this.filePath,
    required this.fileSizeBytes,
  });

  final String filePath;
  final int fileSizeBytes;
}

final class PlaybackAudioArtifact extends AudioArtifact {
  const PlaybackAudioArtifact({
    required super.requestId,
    required super.audioSpec,
    required this.playbackId,
    required this.playbackDuration,
  });

  final String playbackId;
  final Duration playbackDuration;
}

final class MulticastAudioArtifact extends AudioArtifact {
  MulticastAudioArtifact({
    required super.requestId,
    required super.audioSpec,
    required Map<String, AudioArtifact> artifacts,
    required Map<String, TtsError> outputErrors,
  })  : artifacts = Map.unmodifiable(artifacts),
        outputErrors = Map.unmodifiable(outputErrors);

  final Map<String, AudioArtifact> artifacts;
  final Map<String, TtsError> outputErrors;
}
