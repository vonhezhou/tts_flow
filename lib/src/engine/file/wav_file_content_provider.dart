import 'dart:io';
import 'dart:typed_data';

import 'package:tts_flow_dart/src/base/pcm_descriptor.dart';
import 'package:tts_flow_dart/src/base/wav_header.dart';
import 'package:tts_flow_dart/src/core/audio_capability.dart';
import 'package:tts_flow_dart/src/core/audio_spec.dart';
import 'package:tts_flow_dart/src/engine/file/file_content_provider.dart';

enum _WavProviderInputKind { wavFile, rawPcm }

/// Streams raw PCM chunks from either an existing WAV file or raw PCM file.
final class WavFileContentProvider implements FileContentProvider {
  WavFileContentProvider.fromWav(this.filePath)
      : _kind = _WavProviderInputKind.wavFile,
        _pcmDescriptor = _readWavDescriptorSync(filePath);

  WavFileContentProvider.fromPcm(
    this.filePath,
    PcmDescriptor descriptor,
  )   : _kind = _WavProviderInputKind.rawPcm,
        _pcmDescriptor = descriptor;

  final String filePath;
  final _WavProviderInputKind _kind;
  final PcmDescriptor _pcmDescriptor;

  @override
  TtsAudioSpec get audioSpec => TtsAudioSpec(
        format: TtsAudioFormat.pcm,
        pcm: _pcmDescriptor,
      );

  @override
  Set<AudioCapability> get supportedCapabilities => const {
        SimpleFormatCapability(format: TtsAudioFormat.pcm),
      };

  @override
  Stream<Uint8List> readChunks(int chunkSizeBytes) async* {
    if (chunkSizeBytes <= 0) {
      throw ArgumentError.value(
        chunkSizeBytes,
        'chunkSizeBytes',
        'Must be greater than zero.',
      );
    }

    final file = File(filePath);
    if (!await file.exists()) {
      throw ArgumentError.value(filePath, 'filePath', 'File does not exist.');
    }

    final raf = await file.open(mode: FileMode.read);
    try {
      if (_kind == _WavProviderInputKind.wavFile) {
        await raf.setPosition(44);
      } else {
        await raf.setPosition(0);
      }

      while (true) {
        final chunk = await raf.read(chunkSizeBytes);
        if (chunk.isEmpty) {
          break;
        }
        yield Uint8List.fromList(chunk);
      }
    } finally {
      await raf.close();
    }
  }

  static PcmDescriptor _readWavDescriptorSync(String filePath) {
    final file = File(filePath);
    if (!file.existsSync()) {
      throw ArgumentError.value(filePath, 'filePath', 'File does not exist.');
    }
    final raf = file.openSync(mode: FileMode.read);
    try {
      final headerBytes = raf.readSync(44);
      if (headerBytes.length < 44) {
        throw const FormatException(
          'Invalid WAV data: expected at least a 44-byte header.',
        );
      }
      final header = WavHeader.parse(Uint8List.fromList(headerBytes));
      return header.toPcmDescriptor();
    } finally {
      raf.closeSync();
    }
  }
}
