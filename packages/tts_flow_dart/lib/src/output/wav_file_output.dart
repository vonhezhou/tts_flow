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
import 'package:tts_flow_dart/src/core/tts_output_write_context.dart';

const int _defaultWavSampleRateHz = 24000;
const int _defaultWavBitsPerSample = 16;
const int _defaultWavChannels = 1;

final class WavFileOutput implements TtsOutput {
  WavFileOutput(this.filePath, {this.outputId = 'wav-file-output'})
    : _state = _WavFileOutputWriteState();

  final String filePath;
  final _WavFileOutputWriteState _state;

  @override
  final String outputId;

  @override
  Set<AudioCapability> get inAudioCapabilities => {PcmCapability.wav()};

  @override
  Future<void> init() async {}

  @override
  Future<void> startWrite(TtsOutputWriteContext writeContext) async {
    if (writeContext.audioSpec.format != TtsAudioFormat.pcm) {
      throw TtsError(
        code: TtsErrorCode.unsupportedFormat,
        message: 'WavFileOutput only accepts PCM audio format.',
        requestKey: writeContext.requestKey,
      );
    }

    final target = File(filePath);
    await target.parent.create(recursive: true);

    final lockedDescriptor = await _readLockedTargetDescriptor(
      target,
      requestKey: writeContext.requestKey,
    );
    final declaredDescriptor = _resolveDeclaredWriteDescriptor(writeContext);
    if (lockedDescriptor != null &&
        declaredDescriptor != null &&
        lockedDescriptor != declaredDescriptor) {
      throw TtsError(
        code: TtsErrorCode.invalidRequest,
        message:
            'Incoming audio spec does not match the existing target WAV file.',
        requestKey: writeContext.requestKey,
      );
    }

    final tempFile = File('$filePath.tmp');
    if (await tempFile.exists()) {
      await tempFile.delete();
    }

    _state.init(
      writeContext: writeContext,
      tempFile: tempFile,
      lockedDescriptor: lockedDescriptor,
    );
  }

  @override
  Future<void> writeChunk(TtsChunk chunk) async {
    final writeContext = _state.writeContext;
    final sink = _state.sink;
    if (writeContext == null || sink == null) {
      throw StateError('WavFileOutput write has not started.');
    }
    if (chunk.requestKey != writeContext.requestKey) {
      throw StateError('Chunk requestKey does not match active write.');
    }

    if (chunk is! TtsAudioChunk) {
      return;
    }

    try {
      final parsed = _parseChunk(chunk, writeContext: writeContext);
      final lockedDescriptor = _state.lockedDescriptor;
      if (lockedDescriptor != null && lockedDescriptor != parsed.descriptor) {
        throw TtsError(
          code: TtsErrorCode.invalidRequest,
          message:
              'Incoming chunk audio spec does not match the existing target WAV file.',
          requestKey: writeContext.requestKey,
        );
      }

      final existingDescriptor = _state.descriptorFromChunks;
      if (existingDescriptor == null) {
        _state.descriptorFromChunks = parsed.descriptor;
      } else if (existingDescriptor != parsed.descriptor) {
        throw TtsError(
          code: TtsErrorCode.outputWriteFailed,
          message: 'WAV chunk descriptors are inconsistent within a write.',
          requestKey: writeContext.requestKey,
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
      throw StateError('WavFileOutput write has not started.');
    }

    final targetFile = File(filePath);
    try {
      await _state.flushAndCloseSink();
      final descriptor = _resolveWavPcmDescriptor(writeContext);
      final lockedDescriptor = _state.lockedDescriptor;
      if (lockedDescriptor != null && lockedDescriptor != descriptor) {
        throw TtsError(
          code: TtsErrorCode.invalidRequest,
          message:
              'Incoming audio spec does not match the existing target WAV file.',
          requestKey: writeContext.requestKey,
        );
      }

      final existingTarget = await _readExistingTarget(
        targetFile,
        requestKey: writeContext.requestKey,
      );
      if (existingTarget != null && existingTarget.descriptor != descriptor) {
        throw TtsError(
          code: TtsErrorCode.invalidRequest,
          message:
              'Existing target WAV file audio spec changed during the write.',
          requestKey: writeContext.requestKey,
        );
      }

      final writePayloadLength = await tempFile.length();
      final combinedPayloadLength = existingTarget == null
          ? writePayloadLength
          : existingTarget.payloadLengthBytes + writePayloadLength;
      if (combinedPayloadLength > 0xFFFFFFFF) {
        throw TtsError(
          code: TtsErrorCode.outputWriteFailed,
          message: 'WAV payload is too large for canonical header fields.',
          requestKey: writeContext.requestKey,
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
        requestKey: writeContext.requestKey,
      );

      await _rewriteWavHeader(
        targetFile: targetFile,
        descriptor: descriptor,
        dataLengthBytes: combinedPayloadLength,
        requestKey: writeContext.requestKey,
      );

      await tempFile.delete();
      final fileSize = await targetFile.length();

      return FileAudioArtifact(
        requestKey: writeContext.requestKey,
        audioSpec: TtsAudioSpec.pcm(descriptor),
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

  PcmDescriptor _resolveWavPcmDescriptor(TtsOutputWriteContext writeContext) {
    final chunkDescriptor = _state.descriptorFromChunks;
    if (chunkDescriptor != null) {
      return chunkDescriptor;
    }

    final lockedDescriptor = _state.lockedDescriptor;
    if (lockedDescriptor != null) {
      return lockedDescriptor;
    }

    final descriptor = writeContext.audioSpec.pcm;
    if (descriptor != null) {
      return descriptor;
    }

    final sampleRateHz =
        writeContext.options?.sampleRateHz ?? _defaultWavSampleRateHz;
    if (sampleRateHz < wavMinSampleRateHz ||
        sampleRateHz > wavMaxSampleRateHz) {
      throw TtsError(
        code: TtsErrorCode.invalidRequest,
        message: 'Invalid sampleRateHz for WAV output: $sampleRateHz.',
        requestKey: writeContext.requestKey,
      );
    }

    return PcmDescriptor(
      sampleRateHz: sampleRateHz,
      bitsPerSample: _defaultWavBitsPerSample,
      channels: _defaultWavChannels,
      encoding: PcmEncoding.signedInt,
    );
  }

  PcmDescriptor? _resolveDeclaredWriteDescriptor(
    TtsOutputWriteContext writeContext,
  ) {
    if (writeContext.audioSpec.pcm != null) {
      return writeContext.audioSpec.pcm;
    }

    if (writeContext.audioSpec.format == TtsAudioFormat.pcm) {
      final sampleRateHz =
          writeContext.options?.sampleRateHz ?? _defaultWavSampleRateHz;
      if (sampleRateHz < wavMinSampleRateHz ||
          sampleRateHz > wavMaxSampleRateHz) {
        throw TtsError(
          code: TtsErrorCode.invalidRequest,
          message: 'Invalid sampleRateHz for WAV output: $sampleRateHz.',
          requestKey: writeContext.requestKey,
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
    required String requestKey,
  }) async {
    final existingTarget = await _readExistingTarget(
      targetFile,
      requestKey: requestKey,
    );
    return existingTarget?.descriptor;
  }

  Future<void> _appendTempToTarget({
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

  Future<void> _rewriteWavHeader({
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

  Future<_ExistingTargetWav?> _readExistingTarget(
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

  _ParsedWavChunk _parseChunk(
    TtsAudioChunk chunk, {
    required TtsOutputWriteContext writeContext,
  }) {
    final chunkFormat = chunk.audioSpec.format;
    if (chunkFormat == TtsAudioFormat.pcm) {
      final descriptor =
          chunk.audioSpec.pcm ??
          writeContext.audioSpec.pcm ??
          _state.descriptorFromChunks;
      if (descriptor == null) {
        throw TtsError(
          code: TtsErrorCode.invalidRequest,
          message:
              'PCM chunks require a PcmDescriptor in chunk or write context audioSpec.',
          requestKey: writeContext.requestKey,
        );
      }
      return _ParsedWavChunk(descriptor: descriptor, payload: chunk.bytes);
    }

    throw TtsError(
      code: TtsErrorCode.unsupportedFormat,
      message: 'WavFileOutput cannot consume $chunkFormat chunks.',
      requestKey: writeContext.requestKey,
    );
  }
}

final class _WavFileOutputWriteState {
  TtsOutputWriteContext? writeContext;
  File? tempFile;
  IOSink? sink;
  PcmDescriptor? descriptorFromChunks;
  PcmDescriptor? lockedDescriptor;

  void init({
    required TtsOutputWriteContext writeContext,
    required File tempFile,
    required PcmDescriptor? lockedDescriptor,
  }) {
    this.writeContext = writeContext;
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
    writeContext = null;
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
  const _ParsedWavChunk({required this.descriptor, required this.payload});

  final PcmDescriptor descriptor;
  final Uint8List payload;
}
