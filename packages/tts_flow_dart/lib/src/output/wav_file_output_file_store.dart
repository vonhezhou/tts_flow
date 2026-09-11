part of 'wav_file_output.dart';

/// Filesystem operations isolated from [WavFileOutput]'s streaming state.
final class _WavFileStore {
  static Future<PcmDescriptor?> readLockedTargetDescriptor(
    File targetFile, {
    required String requestKey,
  }) async {
    final existingTarget = await readExistingTarget(
      targetFile,
      requestKey: requestKey,
    );
    return existingTarget?.descriptor;
  }

  static Future<void> appendTempToTarget({
    required File targetFile,
    required File tempFile,
    required List<int>? initialBytes,
    required bool append,
    required String requestKey,
  }) async {
    final targetSink = targetFile.openWrite(
      mode: append ? FileMode.append : FileMode.write,
    );
    try {
      if (initialBytes != null) {
        targetSink.add(initialBytes);
      }

      await for (final chunk in tempFile.openRead()) {
        targetSink.add(chunk);
      }

      await targetSink.flush();
    } catch (error) {
      throw TtsError(
        code: TtsErrorCode.outputWriteFailed,
        message: 'Failed appending WAV write payload to target file.',
        requestKey: requestKey,
        cause: error,
      );
    } finally {
      await targetSink.close();
    }
  }

  static Future<void> rewriteWavHeader({
    required File targetFile,
    required PcmDescriptor descriptor,
    required int dataLengthBytes,
    required String requestKey,
  }) async {
    final fileHandle = await targetFile.open(mode: FileMode.writeOnlyAppend);
    try {
      await fileHandle.setPosition(0);
      await fileHandle.writeFrom(
        WavHeader.fromPcmDescriptor(
          descriptor,
          dataLengthBytes: dataLengthBytes,
        ).toBytes(),
      );
    } catch (error) {
      throw TtsError(
        code: TtsErrorCode.outputWriteFailed,
        message: 'Failed updating WAV output header.',
        requestKey: requestKey,
        cause: error,
      );
    } finally {
      await fileHandle.close();
    }
  }

  static Future<_ExistingTargetWav?> readExistingTarget(
    File targetFile, {
    required String requestKey,
  }) async {
    if (!await targetFile.exists()) {
      return null;
    }

    try {
      final fileLength = await targetFile.length();
      if (fileLength < 44) {
        throw const FormatException(
          'Existing WAV file is shorter than canonical header length.',
        );
      }

      final fileHandle = await targetFile.open();
      Uint8List headerBytes;
      try {
        headerBytes = Uint8List.fromList(await fileHandle.read(44));
      } finally {
        await fileHandle.close();
      }

      final header = WavHeader.parse(headerBytes);
      final declaredLength = 44 + header.dataLengthBytes;
      if (fileLength < declaredLength) {
        throw const FormatException(
          'Existing WAV file is shorter than header-declared payload length.',
        );
      }

      return _ExistingTargetWav(
        descriptor: header.toPcmDescriptor(),
        payloadLengthBytes: fileLength - 44,
      );
    } catch (error) {
      if (error is TtsError) {
        rethrow;
      }
      throw TtsError(
        code: TtsErrorCode.outputWriteFailed,
        message: 'Existing target file is not a valid WAV file.',
        requestKey: requestKey,
        cause: error,
      );
    }
  }
}

final class _ExistingTargetWav {
  const _ExistingTargetWav({
    required this.descriptor,
    required this.payloadLengthBytes,
  });

  final PcmDescriptor descriptor;
  final int payloadLengthBytes;
}
