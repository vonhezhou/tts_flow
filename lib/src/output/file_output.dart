import 'dart:io';

import 'package:tts_flow_dart/src/base/pcm_descriptor.dart';
import 'package:tts_flow_dart/src/base/wav_header.dart';
import 'package:tts_flow_dart/src/core/audio_artifact.dart';
import 'package:tts_flow_dart/src/core/audio_capability.dart';
import 'package:tts_flow_dart/src/core/audio_spec.dart';
import 'package:tts_flow_dart/src/core/synthesis_control.dart';
import 'package:tts_flow_dart/src/core/tts_chunk.dart';
import 'package:tts_flow_dart/src/core/tts_errors.dart';
import 'package:tts_flow_dart/src/core/tts_output.dart';
import 'package:tts_flow_dart/src/core/tts_output_session.dart';

const int _defaultPcmSampleRateHz = 24000;
const int _defaultPcmBitsPerSample = 16;
const int _defaultPcmChannels = 1;

final class FileOutput implements TtsOutput {
  FileOutput({
    required Directory outputDirectory,
    this.outputId = 'file-output',
  })  : _outputDirectory = outputDirectory,
        _state = _FileOutputSessionState();

  final Directory _outputDirectory;
  final _FileOutputSessionState _state;

  @override
  final String outputId;

  @override
  Set<AudioCapability> get acceptedCapabilities => TtsAudioFormat.values
      .map((format) => SimpleFormatCapability(format: format))
      .toSet();

  @override
  Future<void> initSession(TtsOutputSession session) async {
    await _outputDirectory.create(recursive: true);
    _state.init(
      session: session,
      tempFile: _buildTempFile(
        requestId: session.requestId,
        audioSpec: session.audioSpec,
      ),
    );
  }

  @override
  Future<void> consumeChunk(TtsChunk chunk) async {
    final session = _state.session;
    final sink = _state.sink;
    if (session == null || sink == null) {
      throw StateError('FileOutput session is not initialized.');
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
        message: 'Failed writing chunk to output file.',
        requestId: session.requestId,
        cause: error,
      );
    }
  }

  @override
  Future<AudioArtifact> finalizeSession() async {
    final session = _state.session;
    final tempFile = _state.tempFile;
    final sink = _state.sink;
    if (session == null || tempFile == null || sink == null) {
      throw StateError('FileOutput session is not initialized.');
    }

    try {
      await _state.flushAndCloseSink();
      final extension = _extensionForFormat(session.audioSpec.format);
      final finalPath =
          '${_outputDirectory.path}${Platform.pathSeparator}${session.requestId}.$extension';
      final targetFile = File(finalPath);
      if (await targetFile.exists()) {
        await targetFile.delete();
      }

      File finalFile;
      if (session.audioSpec.format == TtsAudioFormat.pcm) {
        final descriptor = _resolvePcmDescriptor(session);
        final payloadLength = await tempFile.length();
        final header = WavHeader.fromPcmDescriptor(
          descriptor,
          dataLengthBytes: payloadLength,
        );
        final targetSink = targetFile.openWrite();
        try {
          targetSink.add(header.toBytes());
          await for (final chunk in tempFile.openRead()) {
            targetSink.add(chunk);
          }
          await targetSink.flush();
        } finally {
          await targetSink.close();
        }
        await tempFile.delete();
        finalFile = targetFile;
      } else {
        finalFile = await tempFile.rename(finalPath);
      }

      final size = await finalFile.length();
      _state.clear();

      return FileAudioArtifact(
        requestId: session.requestId,
        audioSpec: session.audioSpec,
        filePath: finalFile.path,
        fileSizeBytes: size,
      );
    } catch (error) {
      await _state.safeCleanupTemp();
      throw TtsError(
        code: TtsErrorCode.outputWriteFailed,
        message: 'Failed finalizing output file.',
        requestId: session.requestId,
        cause: error,
      );
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

  File _buildTempFile({
    required String requestId,
    required TtsAudioSpec audioSpec,
  }) {
    final extension = _extensionForFormat(audioSpec.format);
    final tempPath =
        '${_outputDirectory.path}${Platform.pathSeparator}$requestId.$extension.tmp';
    return File(tempPath);
  }

  String _extensionForFormat(TtsAudioFormat format) {
    switch (format) {
      case TtsAudioFormat.pcm:
        return 'wav';
      case TtsAudioFormat.mp3:
        return 'mp3';
      case TtsAudioFormat.opus:
        return 'ogg';
      case TtsAudioFormat.aac:
        return 'aac';
    }
  }

  PcmDescriptor _resolvePcmDescriptor(TtsOutputSession session) {
    if (session.audioSpec.pcm != null) {
      return session.audioSpec.pcm!;
    }
    return PcmDescriptor(
      sampleRateHz: session.options?.sampleRateHz ?? _defaultPcmSampleRateHz,
      bitsPerSample: _defaultPcmBitsPerSample,
      channels: _defaultPcmChannels,
      encoding: PcmEncoding.signedInt,
    );
  }
}

final class _FileOutputSessionState {
  TtsOutputSession? session;
  File? tempFile;
  IOSink? sink;

  void init({required TtsOutputSession session, required File tempFile}) {
    this.session = session;
    this.tempFile = tempFile;
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
  }
}
