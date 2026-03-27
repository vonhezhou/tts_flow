import 'dart:io';
import 'dart:typed_data';

import 'package:logging/logging.dart';
import 'package:tts_flow_dart/src/base/adts_frame_header.dart';
import 'package:tts_flow_dart/src/core/audio_artifact.dart';
import 'package:tts_flow_dart/src/core/audio_capability.dart';
import 'package:tts_flow_dart/src/core/audio_spec.dart';
import 'package:tts_flow_dart/src/core/synthesis_control.dart';
import 'package:tts_flow_dart/src/core/tts_chunk.dart';
import 'package:tts_flow_dart/src/core/tts_errors.dart';
import 'package:tts_flow_dart/src/core/tts_output.dart';
import 'package:tts_flow_dart/src/core/tts_output_session.dart';

final _log = Logger('tts_flow_dart.AacFileOutput');

/// Writes AAC audio as a flat ADTS stream appended to a single file.
///
/// Each chunk is expected to contain one or more AAC frames prefixed with
/// standard 7-byte ADTS headers (no CRC, protection_absent = 1). Chunks are
/// buffered in a temporary file during a session and merged into [filePath]
/// at finalization. Existing files are never overwritten; new sessions always
/// append.
///
/// If the newly written session uses a different sample rate or channel count
/// than the data already present in the target file, a warning is logged but
/// the append proceeds—ADTS is a self-framing format and each frame carries
/// its own header.
final class AacFileOutput implements TtsOutput {
  AacFileOutput(this.filePath, {this.outputId = 'aac-file-output'})
    : _state = _AacFileOutputSessionState();

  final String filePath;
  final _AacFileOutputSessionState _state;

  @override
  final String outputId;

  @override
  Set<AudioCapability> get acceptedCapabilities => {
    const AacCapability(),
  };

  @override
  Future<void> init() async {}

  @override
  Future<void> initSession(TtsOutputSession session) async {
    if (session.audioSpec.format != TtsAudioFormat.aac) {
      throw TtsError(
        code: TtsErrorCode.unsupportedFormat,
        message: 'AacFileOutput only accepts AAC audio format.',
        requestId: session.requestId,
      );
    }

    final target = File(filePath);
    await target.parent.create(recursive: true);

    final lockedHeader = await _readTargetHeader(target);

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
      throw StateError('AacFileOutput session is not initialized.');
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
        message: 'Failed writing chunk to AAC output file.',
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
      throw StateError('AacFileOutput session is not initialized.');
    }

    final targetFile = File(filePath);
    try {
      await _state.flushAndCloseSink();

      final sessionHeader = await _readSessionHeader(
        tempFile,
        requestId: session.requestId,
      );
      final currentTargetHeader = await _readTargetHeader(targetFile);
      final lockedHeader = _state.lockedHeader;

      if (lockedHeader != null && currentTargetHeader != lockedHeader) {
        _log.warning(
          'AacFileOutput[$outputId]: target file metadata changed during '
          'session — the existing ADTS header no longer matches what was '
          'read at session start.',
        );
      }

      if (currentTargetHeader != null) {
        _warnIfChanged(
          existing: currentTargetHeader,
          incoming: sessionHeader,
          requestId: session.requestId,
        );
      }

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
        message: 'Failed finalizing AAC output file.',
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

  void _warnIfChanged({
    required AdtsFrameHeader existing,
    required AdtsFrameHeader incoming,
    required String requestId,
  }) {
    if (existing.samplingFrequencyIndex != incoming.samplingFrequencyIndex) {
      final existingHz =
          existing.sampleRateHz ?? existing.samplingFrequencyIndex;
      final incomingHz =
          incoming.sampleRateHz ?? incoming.samplingFrequencyIndex;
      _log.warning(
        'AacFileOutput[$outputId]: sample rate changed from $existingHz Hz '
        'to $incomingHz Hz while appending to $filePath '
        '(requestId: $requestId). The resulting file may not play correctly '
        'on all decoders.',
      );
    }

    if (existing.channelConfig != incoming.channelConfig) {
      final existingCh = existing.channelCount ?? existing.channelConfig;
      final incomingCh = incoming.channelCount ?? incoming.channelConfig;
      _log.warning(
        'AacFileOutput[$outputId]: channel count changed from $existingCh '
        'to $incomingCh while appending to $filePath '
        '(requestId: $requestId). The resulting file may not play correctly '
        'on all decoders.',
      );
    }
  }

  /// Reads the first ADTS header from [target], or returns `null` when the
  /// file does not exist or contains no recognisable ADTS data.
  Future<AdtsFrameHeader?> _readTargetHeader(File target) async {
    if (!await target.exists()) {
      return null;
    }

    final fileHandle = await target.open();
    try {
      // 7 bytes is the minimum ADTS header size; read a small probe.
      final probe = Uint8List.fromList(await fileHandle.read(64));
      return AdtsFrameHeader.tryParse(probe);
    } finally {
      await fileHandle.close();
    }
  }

  Future<AdtsFrameHeader> _readSessionHeader(
    File tempFile, {
    required String requestId,
  }) async {
    try {
      final probe = Uint8List.fromList(
        await tempFile.openRead(0, 64).expand((b) => b).toList(),
      );
      return AdtsFrameHeader.parse(probe);
    } on FormatException catch (error) {
      throw TtsError(
        code: TtsErrorCode.outputWriteFailed,
        message: 'Session AAC output does not contain a valid ADTS header.',
        requestId: requestId,
        cause: error,
      );
    }
  }
}

final class _AacFileOutputSessionState {
  TtsOutputSession? session;
  File? tempFile;
  IOSink? sink;
  AdtsFrameHeader? lockedHeader;

  void init({
    required TtsOutputSession session,
    required File tempFile,
    required AdtsFrameHeader? lockedHeader,
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
