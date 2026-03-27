import 'dart:io';
import 'dart:typed_data';

import 'package:tts_flow_dart/src/base/mp3_frame_header.dart';
import 'package:tts_flow_dart/src/core/audio_capability.dart';
import 'package:tts_flow_dart/src/core/audio_spec.dart';
import 'package:tts_flow_dart/src/engine/file/file_content_provider.dart';

/// Streams MP3 audio bytes from a file while stripping common ID3 metadata.
///
/// - ID3v2 header (and optional footer) is skipped from the front.
/// - ID3v1 `TAG` footer is removed from the tail.
final class Mp3FileContentProvider implements FileContentProvider {
  Mp3FileContentProvider(this.filePath);

  final String filePath;

  @override
  TtsAudioSpec get audioSpec => const TtsAudioSpec.mp3();

  @override
  Set<AudioCapability> get supportedCapabilities => const {
        SimpleFormatCapability(format: TtsAudioFormat.mp3),
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
      final fileLength = await raf.length();
      if (fileLength == 0) {
        return;
      }

      await raf.setPosition(0);
      final prefix = Uint8List.fromList(await raf.read(10));
      final startOffset = Mp3FrameHeader.audioStartOffset(prefix);
      if (startOffset == null) {
        throw const FormatException(
            'Invalid MP3 data: incomplete ID3v2 tag header.');
      }

      var endOffset = fileLength;
      if (fileLength >= 128) {
        await raf.setPosition(fileLength - 128);
        final footer = await raf.read(128);
        final hasId3v1Footer = footer.length == 128 &&
            footer[0] == 0x54 &&
            footer[1] == 0x41 &&
            footer[2] == 0x47;
        if (hasId3v1Footer) {
          endOffset = fileLength - 128;
        }
      }

      if (startOffset >= endOffset) {
        return;
      }

      await _validateFirstFrame(
        raf: raf,
        startOffset: startOffset,
        endOffset: endOffset,
      );

      await raf.setPosition(startOffset);
      while (raf.positionSync() < endOffset) {
        final remaining = endOffset - raf.positionSync();
        final readSize =
            remaining < chunkSizeBytes ? remaining : chunkSizeBytes;
        final chunk = await raf.read(readSize);
        if (chunk.isEmpty) {
          break;
        }
        yield Uint8List.fromList(chunk);
      }
    } finally {
      await raf.close();
    }
  }

  Future<void> _validateFirstFrame({
    required RandomAccessFile raf,
    required int startOffset,
    required int endOffset,
  }) async {
    final availableBytes = endOffset - startOffset;
    if (availableBytes < 4) {
      throw const FormatException(
        'Invalid MP3 data: no room for a valid MPEG frame header.',
      );
    }

    final probeSize = availableBytes < 4096 ? availableBytes : 4096;
    await raf.setPosition(startOffset);
    final probe = Uint8List.fromList(await raf.read(probeSize));
    if (Mp3FrameHeader.tryParse(probe) == null) {
      throw const FormatException(
        'Invalid MP3 data: no valid MPEG frame header found after ID3 stripping.',
      );
    }
  }
}
