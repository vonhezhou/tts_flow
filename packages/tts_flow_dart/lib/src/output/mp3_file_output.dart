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
import 'package:tts_flow_dart/src/core/tts_output_write_context.dart';

part 'mp3_file_output_file_store.dart';

final _log = Logger('tts_flow_dart.Mp3FileOutput');

final class Mp3FileOutput implements TtsOutput {
  Mp3FileOutput(this.filePath, {this.outputId = 'mp3-file-output'})
    : _state = _Mp3FileOutputWriteState();

  final String filePath;
  final _Mp3FileOutputWriteState _state;

  @override
  final String outputId;

  @override
  Set<AudioCapability> get inAudioCapabilities => {const Mp3Capability()};

  @override
  Future<void> init() async {}

  @override
  Future<void> startWrite(TtsOutputWriteContext writeContext) async {
    if (writeContext.audioSpec.format != TtsAudioFormat.mp3) {
      throw TtsError(
        code: TtsErrorCode.unsupportedFormat,
        message: 'Mp3FileOutput only accepts MP3 audio format.',
        requestKey: writeContext.requestKey,
      );
    }

    final target = File(filePath);
    await target.parent.create(recursive: true);

    final lockedHeader = await _Mp3FileStore.readTargetHeader(
      target,
      requestKey: writeContext.requestKey,
    );

    final tempFile = File('$filePath.tmp');
    if (await tempFile.exists()) {
      await tempFile.delete();
    }

    _state.init(
      writeContext: writeContext,
      tempFile: tempFile,
      lockedHeader: lockedHeader,
    );
  }

  @override
  Future<void> writeChunk(TtsChunk chunk) async {
    final writeContext = _state.writeContext;
    final sink = _state.sink;
    if (writeContext == null || sink == null) {
      throw StateError('Mp3FileOutput write has not started.');
    }
    if (chunk.requestKey != writeContext.requestKey) {
      throw StateError('Chunk requestKey does not match active write.');
    }

    if (chunk is! TtsAudioChunk) {
      return;
    }

    try {
      sink.add(chunk.bytes);
      await sink.flush();
    } catch (error) {
      throw TtsError(
        code: TtsErrorCode.outputWriteFailed,
        message: 'Failed writing chunk to MP3 output file.',
        requestKey: writeContext.requestKey,
        cause: error,
      );
    }
  }

  @override
  Future<AudioArtifact> finishWrite() async {
    final writeContext = _state.writeContext;
    final tempFile = _state.tempFile;
    if (writeContext == null || tempFile == null) {
      throw StateError('Mp3FileOutput write has not started.');
    }

    final targetFile = File(filePath);
    try {
      await _state.flushAndCloseSink();
      final incomingHeader = await _Mp3FileStore.readIncomingHeader(
        tempFile,
        requestKey: writeContext.requestKey,
      );
      final currentTargetHeader = await _Mp3FileStore.readTargetHeader(
        targetFile,
        requestKey: writeContext.requestKey,
      );
      final lockedHeader = _state.lockedHeader;

      if (lockedHeader != null && currentTargetHeader != lockedHeader) {
        throw TtsError(
          code: TtsErrorCode.invalidRequest,
          message:
              'Existing target MP3 file metadata changed during the write.',
          requestKey: writeContext.requestKey,
        );
      }
      if (currentTargetHeader != null) {
        if (currentTargetHeader.version != incomingHeader.version ||
            currentTargetHeader.layer != incomingHeader.layer) {
          throw TtsError(
            code: TtsErrorCode.invalidRequest,
            message:
                'Incoming MP3 MPEG version/layer does not match the '
                'existing target file and cannot be safely appended.',
            requestKey: writeContext.requestKey,
          );
        }
        if (currentTargetHeader.sampleRateHz != incomingHeader.sampleRateHz) {
          _log.warning(
            'Mp3FileOutput[$outputId]: sample rate changed from '
            '${currentTargetHeader.sampleRateHz} Hz to '
            '${incomingHeader.sampleRateHz} Hz while appending to $filePath '
            '(requestKey: ${writeContext.requestKey}). The resulting file may '
            'play with jumps or glitches.',
          );
        }
        if (currentTargetHeader.channelCount != incomingHeader.channelCount) {
          _log.warning(
            'Mp3FileOutput[$outputId]: channel count changed from '
            '${currentTargetHeader.channelCount} to '
            '${incomingHeader.channelCount} while appending to $filePath '
            '(requestKey: ${writeContext.requestKey}). The resulting file may '
            'play with jumps or glitches.',
          );
        }
      }

      await _Mp3FileStore.stripTrailingId3v1Tag(targetFile);

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
        requestKey: writeContext.requestKey,
        audioSpec: writeContext.audioSpec,
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
        requestKey: writeContext.requestKey,
        cause: error,
      );
    } finally {
      _state.clear();
    }
  }

  @override
  Future<void> cancelWrite(SynthesisControl control) async {
    await _state.safeCleanupTemp();
    _state.clear();
  }

  @override
  Future<void> dispose() async {
    await _state.safeCleanupTemp();
    _state.clear();
  }
}

final class _Mp3FileOutputWriteState {
  TtsOutputWriteContext? writeContext;
  File? tempFile;
  IOSink? sink;
  Mp3FrameHeader? lockedHeader;

  void init({
    required TtsOutputWriteContext writeContext,
    required File tempFile,
    required Mp3FrameHeader? lockedHeader,
  }) {
    this.writeContext = writeContext;
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
    writeContext = null;
    tempFile = null;
    sink = null;
    lockedHeader = null;
  }
}
