import 'dart:typed_data';

import 'package:tts_flow_dart/src/core/audio_capability.dart';
import 'package:tts_flow_dart/src/core/audio_spec.dart';

/// Converts a TtsAudioFormat to the appropriate AudioCapability subclass.
AudioCapability _formatToCapability(TtsAudioFormat format) {
  return switch (format) {
    TtsAudioFormat.pcm => PcmCapability(),
    TtsAudioFormat.mp3 => const Mp3Capability(),
    TtsAudioFormat.opus => const OpusCapability(),
    TtsAudioFormat.aac => const AacCapability(),
  };
}

/// Supplies deterministic audio bytes for [FileTtsEngine].
///
/// Providers are responsible for parsing/normalizing file content and yielding
/// chunk payloads that the engine streams as [TtsChunk.bytes].
abstract interface class FileContentProvider {
  /// The default audio specification represented by this provider's data.
  TtsAudioSpec get audioSpec;

  /// Capabilities supported by this provider for format negotiation.
  Set<AudioCapability> get supportedCapabilities;

  /// Reads normalized content as chunked byte payloads.
  Stream<Uint8List> readChunks(int chunkSizeBytes);
}

/// In-memory provider that serves a fixed byte buffer.
final class RawBytesContentProvider implements FileContentProvider {
  RawBytesContentProvider({
    required Uint8List bytes,
    required this.audioSpec,
    Set<AudioCapability>? supportedCapabilities,
  })  : _bytes = Uint8List.fromList(bytes),
        _supportedCapabilities = Set.unmodifiable(
          supportedCapabilities ??
              <AudioCapability>{
                _formatToCapability(audioSpec.format),
              },
        );

  final Uint8List _bytes;

  @override
  final TtsAudioSpec audioSpec;

  final Set<AudioCapability> _supportedCapabilities;

  @override
  Set<AudioCapability> get supportedCapabilities => _supportedCapabilities;

  @override
  Stream<Uint8List> readChunks(int chunkSizeBytes) async* {
    if (chunkSizeBytes <= 0) {
      throw ArgumentError.value(
        chunkSizeBytes,
        'chunkSizeBytes',
        'Must be greater than zero.',
      );
    }

    for (var start = 0; start < _bytes.length; start += chunkSizeBytes) {
      final end = (start + chunkSizeBytes > _bytes.length)
          ? _bytes.length
          : start + chunkSizeBytes;
      yield Uint8List.fromList(_bytes.sublist(start, end));
    }
  }
}
