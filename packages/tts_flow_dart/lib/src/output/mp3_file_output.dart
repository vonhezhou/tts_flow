import 'dart:io';
import 'dart:typed_data';

import 'package:logging/logging.dart';
import 'package:tts_flow_dart/src/base/mp3_frame_header.dart';
import 'package:tts_flow_dart/src/core/audio_artifact.dart';
import 'package:tts_flow_dart/src/core/audio_capability.dart';
import 'package:tts_flow_dart/src/core/audio_spec.dart';
import 'package:tts_flow_dart/src/core/synthesis_control.dart';
import 'package:tts_flow_dart/src/core/tts_chunk.dart';
import 'package:tts_flow_dart/src/core/tts_errors.dart';
import 'package:tts_flow_dart/src/core/tts_output.dart';
import 'package:tts_flow_dart/src/core/tts_output_session.dart';

final _log = Logger('tts_flow_dart.Mp3FileOutput');

final class Mp3FileOutput implements TtsOutput {
  Mp3FileOutput(this.filePath, {this.outputId = 'mp3-file-output'})
    : _state = _Mp3FileOutputSessionState();

  final String filePath;
  final _Mp3FileOutputSessionState _state;

  @override
  final String outputId;

  @override
  Set<AudioCapability> get acceptedCapabilities => {
    const Mp3Capability(),
  };

  @override
  Future<void> init() async {}

  @override
  Future<void> initSession(TtsOutputSession session) async {
    if (session.audioSpec.format != TtsAudioFormat.mp3) {
      throw TtsError(
        code: TtsErrorCode.unsupportedFormat,
        message: 'Mp3FileOutput only accepts MP3 audio format.',
        requestId: session.requestId,
      );
    }

    final target = File(filePath);
    await target.parent.create(recursive: true);

    final lockedHeader = await _readTargetHeader(
      target,
      requestId: session.requestId,
    );

    final tempFile = File('$filePath.tmp');
    if (await tempFile.exists()) {
      await tempFile.delete();
    }

    _state.init(
      session: session,
      tempFile: tempFile,
      lockedHeader: lockedHeader,
    );
  }

  @override
  Future<void> consumeChunk(TtsChunk chunk) async {
    final session = _state.session;
    final sink = _state.sink;
    if (session == null || sink == null) {
      throw StateError('Mp3FileOutput session is not initialized.');
    }
    if (chunk.requestId != session.requestId) {
      throw StateError('Chunk requestId does not match active session.');
    }

    try {
      sink.add(chunk.bytes);
      await sink.flush();
    } catch (error) {
      throw TtsError(
        code: TtsErrorCode.outputWriteFailed,
        message: 'Failed writing chunk to MP3 output file.',
        requestId: session.requestId,
        cause: error,
      );
    }
  }

  @override
  Future<AudioArtifact> finalizeSession() async {
    final session = _state.session;
    final tempFile = _state.tempFile;
    if (session == null || tempFile == null) {
      throw StateError('Mp3FileOutput session is not initialized.');
    }

    final targetFile = File(filePath);
    try {
      await _state.flushAndCloseSink();
      final sessionHeader = await _readSessionHeader(
        tempFile,
        requestId: session.requestId,
      );
      final currentTargetHeader = await _readTargetHeader(
        targetFile,
        requestId: session.requestId,
      );
      final lockedHeader = _state.lockedHeader;

      if (lockedHeader != null && currentTargetHeader != lockedHeader) {
        throw TtsError(
          code: TtsErrorCode.invalidRequest,
          message:
              'Existing target MP3 file metadata changed during the session.',
          requestId: session.requestId,
        );
      }
      if (currentTargetHeader != null) {
        if (currentTargetHeader.version != sessionHeader.version ||
            currentTargetHeader.layer != sessionHeader.layer) {
          throw TtsError(
            code: TtsErrorCode.invalidRequest,
            message:
                'Session MP3 MPEG version/layer does not match the '
                'existing target file and cannot be safely appended.',
            requestId: session.requestId,
          );
        }
        if (currentTargetHeader.sampleRateHz != sessionHeader.sampleRateHz) {
          _log.warning(
            'Mp3FileOutput[$outputId]: sample rate changed from '
            '${currentTargetHeader.sampleRateHz} Hz to '
            '${sessionHeader.sampleRateHz} Hz while appending to $filePath '
            '(requestId: ${session.requestId}). The resulting file may '
            'play with jumps or glitches.',
          );
        }
        if (currentTargetHeader.channelCount != sessionHeader.channelCount) {
          _log.warning(
            'Mp3FileOutput[$outputId]: channel count changed from '
            '${currentTargetHeader.channelCount} to '
            '${sessionHeader.channelCount} while appending to $filePath '
            '(requestId: ${session.requestId}). The resulting file may '
            'play with jumps or glitches.',
          );
        }
      }

      await _stripTrailingId3v1Tag(targetFile);

      final targetSink = targetFile.openWrite(
        mode: await targetFile.exists() ? FileMode.append : FileMode.write,
      );
      try {
        await targetSink.addStream(tempFile.openRead());
        await targetSink.flush();
      } finally {
        await targetSink.close();
      }

      await tempFile.delete();
      final fileSize = await targetFile.length();

      return FileAudioArtifact(
        requestId: session.requestId,
        audioSpec: session.audioSpec,
        filePath: targetFile.path,
        fileSizeBytes: fileSize,
      );
    } catch (error) {
      await _state.safeCleanupTemp();
      if (error is TtsError) {
        rethrow;
      }
      throw TtsError(
        code: TtsErrorCode.outputWriteFailed,
        message: 'Failed finalizing MP3 output file.',
        requestId: session.requestId,
        cause: error,
      );
    } finally {
      _state.clear();
    }
  }

  @override
  Future<void> onCancel(SynthesisControl control) async {
    await _state.safeCleanupTemp();
    _state.clear();
  }

  @override
  Future<void> dispose() async {
    await _state.safeCleanupTemp();
    _state.clear();
  }

  Future<Mp3FrameHeader?> _readTargetHeader(
    File target, {
    required String requestId,
  }) async {
    if (!await target.exists()) {
      return null;
    }

    try {
      return Mp3FrameHeader.parse(await _readMp3HeaderProbe(target));
    } on FormatException catch (error) {
      throw TtsError(
        code: TtsErrorCode.invalidRequest,
        message:
            'Existing target MP3 file does not contain a valid frame header.',
        requestId: requestId,
        cause: error,
      );
    }
  }

  Future<Mp3FrameHeader> _readSessionHeader(
    File tempFile, {
    required String requestId,
  }) async {
    try {
      return Mp3FrameHeader.parse(await tempFile.readAsBytes());
    } on FormatException catch (error) {
      throw TtsError(
        code: TtsErrorCode.invalidRequest,
        message: 'Session MP3 output does not contain a valid frame header.',
        requestId: requestId,
        cause: error,
      );
    }
  }

  /// Reads only the prefix needed to parse the first MPEG frame header.
  ///
  /// MP3 targets may begin with an ID3v2 tag, so this first reads the
  /// canonical 10-byte ID3 header. If no ID3 tag is present, only the first
  /// 4 bytes are needed to probe the initial MPEG frame header. When an ID3
  /// tag is present, this returns the full tag span, any optional footer, and
  /// 4 additional bytes so [Mp3FrameHeader.parse] can inspect the first audio
  /// frame without loading the entire file into memory.
  Future<Uint8List> _readMp3HeaderProbe(File target) async {
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
      final int probeLength = 10 + tagSize + footerLength + 4;

      await fileHandle.setPosition(0);
      return Uint8List.fromList(await fileHandle.read(probeLength));
    } finally {
      await fileHandle.close();
    }
  }

  /// Removes a trailing ID3v1 TAG footer (128 bytes) from an existing file.
  ///
  /// This is called before append finalization so new MPEG frames are not
  /// written after stale trailing metadata that some players treat as EOF.
  Future<void> _stripTrailingId3v1Tag(File targetFile) async {
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
      if (!hasId3v1Tag) {
        return;
      }

      await randomAccessFile.truncate(fileLength - 128);
    } finally {
      await randomAccessFile.close();
    }
  }
}

final class _Mp3FileOutputSessionState {
  TtsOutputSession? session;
  File? tempFile;
  IOSink? sink;
  Mp3FrameHeader? lockedHeader;

  void init({
    required TtsOutputSession session,
    required File tempFile,
    required Mp3FrameHeader? lockedHeader,
  }) {
    this.session = session;
    this.tempFile = tempFile;
    this.lockedHeader = lockedHeader;
    sink = tempFile.openWrite();
  }

  Future<void> flushAndCloseSink() async {
    final activeSink = sink;
    if (activeSink == null) {
      return;
    }
    await activeSink.flush();
    await activeSink.close();
  }

  Future<void> safeCleanupTemp() async {
    final activeSink = sink;
    if (activeSink != null) {
      try {
        await activeSink.flush();
      } catch (_) {
        // No-op: cleanup continues.
      }
      try {
        await activeSink.close();
      } catch (_) {
        // No-op: cleanup continues.
      }
    }

    final activeTempFile = tempFile;
    if (activeTempFile != null && await activeTempFile.exists()) {
      try {
        await activeTempFile.delete();
      } catch (_) {
        // No-op: best-effort cleanup.
      }
    }
  }

  void clear() {
    session = null;
    tempFile = null;
    sink = null;
    lockedHeader = null;
  }
}
