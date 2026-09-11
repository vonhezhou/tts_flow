part of 'mp3_file_output.dart';

/// Filesystem metadata operations isolated from [Mp3FileOutput]'s write state.
final class _Mp3FileStore {
  static Future<Mp3FrameHeader?> readTargetHeader(
    File target, {
    required String requestKey,
  }) async {
    if (!await target.exists()) {
      return null;
    }

    try {
      return Mp3FrameHeader.parse(await _readHeaderProbe(target));
    } on FormatException catch (error) {
      throw TtsError(
        code: TtsErrorCode.invalidRequest,
        message:
            'Existing target MP3 file does not contain a valid frame header.',
        requestKey: requestKey,
        cause: error,
      );
    }
  }

  static Future<Mp3FrameHeader> readIncomingHeader(
    File tempFile, {
    required String requestKey,
  }) async {
    try {
      return Mp3FrameHeader.parse(await tempFile.readAsBytes());
    } on FormatException catch (error) {
      throw TtsError(
        code: TtsErrorCode.invalidRequest,
        message: 'Incoming MP3 audio does not contain a valid frame header.',
        requestKey: requestKey,
        cause: error,
      );
    }
  }

  /// Reads only the prefix needed to parse the first MPEG frame header.
  static Future<Uint8List> _readHeaderProbe(File target) async {
    final fileHandle = await target.open();
    try {
      final prefix = Uint8List.fromList(await fileHandle.read(10));
      if (prefix.length < 10) {
        return prefix;
      }

      if (prefix[0] != 0x49 || prefix[1] != 0x44 || prefix[2] != 0x33) {
        await fileHandle.setPosition(0);
        return Uint8List.fromList(await fileHandle.read(4));
      }

      final flags = prefix[5];
      final tagSize =
          ((prefix[6] & 0x7F) << 21) |
          ((prefix[7] & 0x7F) << 14) |
          ((prefix[8] & 0x7F) << 7) |
          (prefix[9] & 0x7F);
      final footerLength = (flags & 0x10) != 0 ? 10 : 0;
      final probeLength = 10 + tagSize + footerLength + 4;

      await fileHandle.setPosition(0);
      return Uint8List.fromList(await fileHandle.read(probeLength));
    } finally {
      await fileHandle.close();
    }
  }

  /// Removes a trailing ID3v1 tag before appending new MPEG frames.
  static Future<void> stripTrailingId3v1Tag(File targetFile) async {
    if (!await targetFile.exists()) {
      return;
    }

    final fileLength = await targetFile.length();
    if (fileLength < 128) {
      return;
    }

    final randomAccessFile = await targetFile.open(mode: FileMode.append);
    try {
      await randomAccessFile.setPosition(fileLength - 128);
      final trailingBlock = await randomAccessFile.read(128);
      if (trailingBlock.length < 128) {
        return;
      }

      final hasId3v1Tag =
          trailingBlock[0] == 0x54 &&
          trailingBlock[1] == 0x41 &&
          trailingBlock[2] == 0x47;
      if (hasId3v1Tag) {
        await randomAccessFile.truncate(fileLength - 128);
      }
    } finally {
      await randomAccessFile.close();
    }
  }
}
