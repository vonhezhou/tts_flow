import 'dart:io';
import 'dart:typed_data';

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

const int _defaultWavSampleRateHz = 24000;
const int _defaultWavBitsPerSample = 16;
const int _defaultWavChannels = 1;

final class WavFileOutput implements TtsOutput {
  WavFileOutput(
    this.filePath, {
    this.outputId = 'wav-file-output',
  }) : _state = _WavFileOutputSessionState();

  final String filePath;
  final _WavFileOutputSessionState _state;

  @override
  final String outputId;

  @override
  Set<AudioCapability> get acceptedCapabilities => {
        const SimpleFormatCapability(format: TtsAudioFormat.wav),
        const SimpleFormatCapability(format: TtsAudioFormat.pcm),
      };

  @override
  Future<void> initSession(TtsOutputSession session) async {
    if (session.audioSpec.format != TtsAudioFormat.wav &&
        session.audioSpec.format != TtsAudioFormat.pcm) {
      throw TtsError(
        code: TtsErrorCode.unsupportedFormat,
        message: 'WavFileOutput only accepts WAV or PCM audio format.',
        requestId: session.requestId,
      );
    }

    final target = File(filePath);
    await target.parent.create(recursive: true);

    final lockedDescriptor =
        await _readLockedTargetDescriptor(target, requestId: session.requestId);
    final declaredDescriptor = _resolveDeclaredSessionDescriptor(session);
    if (lockedDescriptor != null &&
        declaredDescriptor != null &&
        lockedDescriptor != declaredDescriptor) {
      throw TtsError(
        code: TtsErrorCode.invalidRequest,
        message:
            'Session audio spec does not match the existing target WAV file.',
        requestId: session.requestId,
      );
    }

    final tempFile = File('$filePath.tmp');
    if (await tempFile.exists()) {
      await tempFile.delete();
    }

    _state.init(
      session: session,
      tempFile: tempFile,
      lockedDescriptor: lockedDescriptor,
    );
  }

  @override
  Future<void> consumeChunk(TtsChunk chunk) async {
    final session = _state.session;
    final sink = _state.sink;
    if (session == null || sink == null) {
      throw StateError('WavFileOutput session is not initialized.');
    }
    if (chunk.requestId != session.requestId) {
      throw StateError('Chunk requestId does not match active session.');
    }

    try {
      final parsed = _parseChunk(
        chunk,
        session: session,
      );
      final lockedDescriptor = _state.lockedDescriptor;
      if (lockedDescriptor != null && lockedDescriptor != parsed.descriptor) {
        throw TtsError(
          code: TtsErrorCode.invalidRequest,
          message:
              'Incoming chunk audio spec does not match the existing target WAV file.',
          requestId: session.requestId,
        );
      }

      final existingDescriptor = _state.descriptorFromChunks;
      if (existingDescriptor == null) {
        _state.descriptorFromChunks = parsed.descriptor;
      } else if (existingDescriptor != parsed.descriptor) {
        throw TtsError(
          code: TtsErrorCode.outputWriteFailed,
          message: 'WAV chunk descriptors are inconsistent within a session.',
          requestId: session.requestId,
        );
      }

      sink.add(parsed.payload);
      await sink.flush();
    } catch (error) {
      if (error is TtsError) {
        rethrow;
      }
      throw TtsError(
        code: TtsErrorCode.outputWriteFailed,
        message: 'Failed writing chunk to WAV output file.',
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
      throw StateError('WavFileOutput session is not initialized.');
    }

    final targetFile = File(filePath);
    try {
      await _state.flushAndCloseSink();
      final descriptor = _resolveWavPcmDescriptor(session);
      final lockedDescriptor = _state.lockedDescriptor;
      if (lockedDescriptor != null && lockedDescriptor != descriptor) {
        throw TtsError(
          code: TtsErrorCode.invalidRequest,
          message:
              'Session audio spec does not match the existing target WAV file.',
          requestId: session.requestId,
        );
      }

      final existingTarget = await _readExistingTarget(
        targetFile,
        requestId: session.requestId,
      );
      if (existingTarget != null && existingTarget.descriptor != descriptor) {
        throw TtsError(
          code: TtsErrorCode.invalidRequest,
          message:
              'Existing target WAV file audio spec changed during the session.',
          requestId: session.requestId,
        );
      }

      final sessionPayloadLength = await tempFile.length();
      final combinedPayloadLength = existingTarget == null
          ? sessionPayloadLength
          : existingTarget.payloadLengthBytes + sessionPayloadLength;
      if (combinedPayloadLength > 0xFFFFFFFF) {
        throw TtsError(
          code: TtsErrorCode.outputWriteFailed,
          message: 'WAV payload is too large for canonical header fields.',
          requestId: session.requestId,
        );
      }

      await _appendTempToTarget(
        targetFile: targetFile,
        tempFile: tempFile,
        initialBytes: existingTarget == null
            ? WavHeader.fromPcmDescriptor(
                descriptor,
                dataLengthBytes: 0,
              ).toBytes()
            : null,
        append: existingTarget != null,
        requestId: session.requestId,
      );

      await _rewriteWavHeader(
        targetFile: targetFile,
        descriptor: descriptor,
        dataLengthBytes: combinedPayloadLength,
        requestId: session.requestId,
      );

      await tempFile.delete();
      final fileSize = await targetFile.length();

      return FileAudioArtifact(
        requestId: session.requestId,
        audioSpec: TtsAudioSpec(
          format: TtsAudioFormat.wav,
          pcm: descriptor,
        ),
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
        message: 'Failed finalizing WAV output file.',
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

  PcmDescriptor _resolveWavPcmDescriptor(TtsOutputSession session) {
    final chunkDescriptor = _state.descriptorFromChunks;
    if (chunkDescriptor != null) {
      return chunkDescriptor;
    }

    final lockedDescriptor = _state.lockedDescriptor;
    if (lockedDescriptor != null) {
      return lockedDescriptor;
    }

    final descriptor = session.audioSpec.pcm;
    if (descriptor != null) {
      return descriptor;
    }

    final sampleRateHz =
        session.options?.sampleRateHz ?? _defaultWavSampleRateHz;
    if (sampleRateHz < wavMinSampleRateHz ||
        sampleRateHz > wavMaxSampleRateHz) {
      throw TtsError(
        code: TtsErrorCode.invalidRequest,
        message: 'Invalid sampleRateHz for WAV output: $sampleRateHz.',
        requestId: session.requestId,
      );
    }

    return PcmDescriptor(
      sampleRateHz: sampleRateHz,
      bitsPerSample: _defaultWavBitsPerSample,
      channels: _defaultWavChannels,
      encoding: PcmEncoding.signedInt,
    );
  }

  PcmDescriptor? _resolveDeclaredSessionDescriptor(TtsOutputSession session) {
    if (session.audioSpec.pcm != null) {
      return session.audioSpec.pcm;
    }

    if (session.audioSpec.format == TtsAudioFormat.pcm) {
      final sampleRateHz =
          session.options?.sampleRateHz ?? _defaultWavSampleRateHz;
      if (sampleRateHz < wavMinSampleRateHz ||
          sampleRateHz > wavMaxSampleRateHz) {
        throw TtsError(
          code: TtsErrorCode.invalidRequest,
          message: 'Invalid sampleRateHz for WAV output: $sampleRateHz.',
          requestId: session.requestId,
        );
      }

      return PcmDescriptor(
        sampleRateHz: sampleRateHz,
        bitsPerSample: _defaultWavBitsPerSample,
        channels: _defaultWavChannels,
        encoding: PcmEncoding.signedInt,
      );
    }

    return null;
  }

  Future<PcmDescriptor?> _readLockedTargetDescriptor(
    File targetFile, {
    required String requestId,
  }) async {
    final existingTarget = await _readExistingTarget(
      targetFile,
      requestId: requestId,
    );
    return existingTarget?.descriptor;
  }

  Future<void> _appendTempToTarget({
    required File targetFile,
    required File tempFile,
    required List<int>? initialBytes,
    required bool append,
    required String requestId,
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
        message: 'Failed appending WAV session payload to target file.',
        requestId: requestId,
        cause: error,
      );
    } finally {
      await targetSink.close();
    }
  }

  Future<void> _rewriteWavHeader({
    required File targetFile,
    required PcmDescriptor descriptor,
    required int dataLengthBytes,
    required String requestId,
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
        requestId: requestId,
        cause: error,
      );
    } finally {
      await fileHandle.close();
    }
  }

  Future<_ExistingTargetWav?> _readExistingTarget(
    File targetFile, {
    required String requestId,
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
        requestId: requestId,
        cause: error,
      );
    }
  }

  _ParsedWavChunk _parseChunk(
    TtsChunk chunk, {
    required TtsOutputSession session,
  }) {
    final chunkFormat = chunk.audioSpec.format;
    if (chunkFormat == TtsAudioFormat.wav) {
      try {
        final header = WavHeader.parse(chunk.bytes);
        if (chunk.bytes.length < 44) {
          throw const FormatException(
              'WAV chunk is shorter than 44-byte header.');
        }
        final payload = Uint8List.fromList(chunk.bytes.sublist(44));
        return _ParsedWavChunk(
          descriptor: header.toPcmDescriptor(),
          payload: payload,
        );
      } catch (error) {
        throw TtsError(
          code: TtsErrorCode.outputWriteFailed,
          message: 'Expected WAV-framed bytes in WAV chunk for WavFileOutput.',
          requestId: session.requestId,
          cause: error,
        );
      }
    }

    if (chunkFormat == TtsAudioFormat.pcm) {
      final descriptor = chunk.audioSpec.pcm ??
          session.audioSpec.pcm ??
          _state.descriptorFromChunks;
      if (descriptor == null) {
        throw TtsError(
          code: TtsErrorCode.invalidRequest,
          message:
              'PCM chunks require a PcmDescriptor in chunk or session audioSpec.',
          requestId: session.requestId,
        );
      }
      return _ParsedWavChunk(
        descriptor: descriptor,
        payload: chunk.bytes,
      );
    }

    throw TtsError(
      code: TtsErrorCode.unsupportedFormat,
      message: 'WavFileOutput cannot consume $chunkFormat chunks.',
      requestId: session.requestId,
    );
  }
}

final class _WavFileOutputSessionState {
  TtsOutputSession? session;
  File? tempFile;
  IOSink? sink;
  PcmDescriptor? descriptorFromChunks;
  PcmDescriptor? lockedDescriptor;

  void init({
    required TtsOutputSession session,
    required File tempFile,
    required PcmDescriptor? lockedDescriptor,
  }) {
    this.session = session;
    this.tempFile = tempFile;
    this.lockedDescriptor = lockedDescriptor;
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
    descriptorFromChunks = null;
    lockedDescriptor = null;
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

final class _ParsedWavChunk {
  const _ParsedWavChunk({
    required this.descriptor,
    required this.payload,
  });

  final PcmDescriptor descriptor;
  final Uint8List payload;
}
