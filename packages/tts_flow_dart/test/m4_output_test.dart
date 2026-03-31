import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:tts_flow_dart/tts_flow_dart.dart';

const _pcmDescriptor = PcmDescriptor(
  sampleRateHz: 24000,
  bitsPerSample: 16,
  channels: 1,
);

const _pcmSpec = TtsAudioSpec.pcm(_pcmDescriptor);
const _mp3Spec = TtsAudioSpec.mp3();

void main() {
  group('M4 mp3 frame header', () {
    test('parses frame metadata and skips ID3v2 tag', () {
      final bytes = _mp3Bytes(
        frames: 1,
        includeId3v2Tag: true,
        version: Mp3MpegVersion.mpeg25,
        sampleRateHz: 8000,
        channelMode: Mp3ChannelMode.mono,
      );

      final header = Mp3FrameHeader.parse(bytes);

      expect(header.version, Mp3MpegVersion.mpeg25);
      expect(header.layer, Mp3Layer.layer3);
      expect(header.sampleRateHz, 8000);
      expect(header.channelMode, Mp3ChannelMode.mono);
      expect(header.channelCount, 1);
    });
  });

  group('M4 memory output', () {
    test('returns bytes and resolved format', () async {
      final output = MemoryOutput();
      const session = TtsOutputSession(
        requestId: 'mem-1',
        audioSpec: _pcmSpec,
        voice: null,
        options: null,
      );

      await output.initSession(session);
      await output.consumeChunk(_chunk('mem-1', 0, [1, 2], TtsAudioFormat.pcm));
      await output.consumeChunk(
        _chunk('mem-1', 1, [3], TtsAudioFormat.pcm, isLast: true),
      );
      final artifact = await output.finalizeSession();

      expect(artifact, isA<InMemoryAudioArtifact>());
      final mem = artifact as InMemoryAudioArtifact;
      expect(mem.requestId, 'mem-1');
      expect(mem.audioSpec.format, TtsAudioFormat.pcm);
      expect(mem.totalBytes, 3);
      expect(mem.audioBytes, Uint8List.fromList([1, 2, 3]));
    });

    test('isolates bytes across sessions', () async {
      final output = MemoryOutput();

      await output.initSession(
        const TtsOutputSession(
          requestId: 'a',
          audioSpec: _mp3Spec,
          voice: null,
          options: null,
        ),
      );
      await output.consumeChunk(
        _chunk('a', 0, [8, 8], TtsAudioFormat.mp3, isLast: true),
      );
      final first = await output.finalizeSession() as InMemoryAudioArtifact;

      await output.initSession(
        const TtsOutputSession(
          requestId: 'b',
          audioSpec: _pcmSpec,
          voice: null,
          options: null,
        ),
      );
      await output.consumeChunk(
        _chunk('b', 0, [7], TtsAudioFormat.pcm, isLast: true),
      );
      final second = await output.finalizeSession() as InMemoryAudioArtifact;

      expect(first.audioBytes, Uint8List.fromList([8, 8]));
      expect(second.audioBytes, Uint8List.fromList([7]));
    });
  });

  group('M4 null output', () {
    test('discards bytes and returns empty artifact payload', () async {
      final output = NullOutput();
      const session = TtsOutputSession(
        requestId: 'null-1',
        audioSpec: _pcmSpec,
        voice: null,
        options: null,
      );

      await output.initSession(session);
      await output.consumeChunk(
        _chunk('null-1', 0, [1, 2], TtsAudioFormat.pcm),
      );
      await output.consumeChunk(
        _chunk('null-1', 1, [3], TtsAudioFormat.pcm, isLast: true),
      );

      final artifact = await output.finalizeSession() as InMemoryAudioArtifact;
      expect(artifact.requestId, 'null-1');
      expect(artifact.audioSpec.format, TtsAudioFormat.pcm);
      expect(artifact.totalBytes, 0);
      expect(artifact.audioBytes, isEmpty);
    });

    test('rejects chunk requestId mismatch', () async {
      final output = NullOutput();
      const session = TtsOutputSession(
        requestId: 'null-2',
        audioSpec: _mp3Spec,
        voice: null,
        options: null,
      );

      await output.initSession(session);

      await expectLater(
        output.consumeChunk(_chunk('other', 0, [9], TtsAudioFormat.mp3)),
        throwsA(isA<StateError>()),
      );
    });
  });

  group('M4 wav/mp3 file outputs', () {
    test('WavFileOutput writes to explicit file path and finalizes', () async {
      final tempDir = await Directory.systemTemp.createTemp(
        'uni_tts_wav_file_output_',
      );
      try {
        final outputPath =
            '${tempDir.path}${Platform.pathSeparator}fixed-output.wav';
        final output = WavFileOutput(outputPath);

        const descriptor = PcmDescriptor(
          sampleRateHz: 16000,
          bitsPerSample: 16,
          channels: 1,
        );
        const session = TtsOutputSession(
          requestId: 'wav-1',
          audioSpec: TtsAudioSpec.pcm(descriptor),
          voice: null,
          options: TtsOptions(sampleRateHz: 16000),
        );

        await output.initSession(session);
        await output.consumeChunk(_pcmChunk('wav-1', 0, [1, 2, 3], descriptor));
        await output.consumeChunk(
          _pcmChunk('wav-1', 1, [4], descriptor, isLast: true),
        );

        final artifact = await output.finalizeSession();
        expect(artifact, isA<FileAudioArtifact>());

        final fileArtifact = artifact as FileAudioArtifact;
        expect(fileArtifact.audioSpec.format, TtsAudioFormat.pcm);
        expect(fileArtifact.filePath, outputPath);
        expect(fileArtifact.fileSizeBytes, 48);
        expect(await File('$outputPath.backup.tmp').exists(), isFalse);

        final fileBytes = await File(outputPath).readAsBytes();
        final header = WavHeader.parse(fileBytes);
        expect(header.sampleRateHz, 16000);
        expect(header.bitsPerSample, 16);
        expect(header.channels, 1);
        expect(header.dataLengthBytes, 4);
        expect(fileBytes.sublist(44), [1, 2, 3, 4]);
      } finally {
        await tempDir.delete(recursive: true);
      }
    });

    test('Mp3FileOutput writes to explicit file path and finalizes', () async {
      final tempDir = await Directory.systemTemp.createTemp(
        'uni_tts_mp3_file_output_',
      );
      try {
        final outputPath =
            '${tempDir.path}${Platform.pathSeparator}fixed-output.mp3';
        final output = Mp3FileOutput(outputPath);
        final bytes = _mp3Bytes(frames: 1);

        const session = TtsOutputSession(
          requestId: 'mp3-1',
          audioSpec: _mp3Spec,
          voice: null,
          options: null,
        );

        await output.initSession(session);
        await output.consumeChunk(
          _chunk('mp3-1', 0, bytes.sublist(0, 20), TtsAudioFormat.mp3),
        );
        await output.consumeChunk(
          _chunk(
            'mp3-1',
            1,
            bytes.sublist(20),
            TtsAudioFormat.mp3,
            isLast: true,
          ),
        );

        final artifact = await output.finalizeSession();
        expect(artifact, isA<FileAudioArtifact>());

        final fileArtifact = artifact as FileAudioArtifact;
        expect(fileArtifact.filePath, outputPath);
        expect(fileArtifact.fileSizeBytes, bytes.length);
        expect(await File(outputPath).readAsBytes(), bytes);
        expect(await File('$outputPath.backup.tmp').exists(), isFalse);
      } finally {
        await tempDir.delete(recursive: true);
      }
    });

    test('Mp3FileOutput appends across sessions', () async {
      final tempDir = await Directory.systemTemp.createTemp(
        'uni_tts_mp3_append_',
      );
      try {
        final outputPath = '${tempDir.path}${Platform.pathSeparator}append.mp3';
        final output = Mp3FileOutput(outputPath);
        final firstBytes = _mp3Bytes(frames: 1, bitrateKbps: 8);
        final secondBytes = _mp3Bytes(frames: 1, bitrateKbps: 16);

        await output.initSession(
          const TtsOutputSession(
            requestId: 'mp3-append-1',
            audioSpec: _mp3Spec,
            voice: null,
            options: null,
          ),
        );
        await output.consumeChunk(
          _chunk('mp3-append-1', 0, firstBytes, TtsAudioFormat.mp3),
        );
        await output.finalizeSession();

        await output.initSession(
          const TtsOutputSession(
            requestId: 'mp3-append-2',
            audioSpec: _mp3Spec,
            voice: null,
            options: null,
          ),
        );
        await output.consumeChunk(
          _chunk(
            'mp3-append-2',
            0,
            secondBytes,
            TtsAudioFormat.mp3,
            isLast: true,
          ),
        );

        final artifact = await output.finalizeSession() as FileAudioArtifact;
        expect(artifact.filePath, outputPath);
        expect(artifact.fileSizeBytes, firstBytes.length + secondBytes.length);
        expect(
          await File(outputPath).readAsBytes(),
          Uint8List.fromList([...firstBytes, ...secondBytes]),
        );
      } finally {
        await tempDir.delete(recursive: true);
      }
    });

    test('Mp3FileOutput strips trailing ID3v1 TAG before appending', () async {
      final tempDir = await Directory.systemTemp.createTemp(
        'uni_tts_mp3_append_id3v1_',
      );
      try {
        final outputPath =
            '${tempDir.path}${Platform.pathSeparator}append-id3v1.mp3';
        final output = Mp3FileOutput(outputPath);
        final firstBytes = _mp3Bytes(
          frames: 1,
          bitrateKbps: 8,
          includeId3v1Tag: true,
        );
        final secondBytes = _mp3Bytes(frames: 1, bitrateKbps: 16);

        await output.initSession(
          const TtsOutputSession(
            requestId: 'mp3-append-id3v1-1',
            audioSpec: _mp3Spec,
            voice: null,
            options: null,
          ),
        );
        await output.consumeChunk(
          _chunk('mp3-append-id3v1-1', 0, firstBytes, TtsAudioFormat.mp3),
        );
        await output.finalizeSession();

        await output.initSession(
          const TtsOutputSession(
            requestId: 'mp3-append-id3v1-2',
            audioSpec: _mp3Spec,
            voice: null,
            options: null,
          ),
        );
        await output.consumeChunk(
          _chunk(
            'mp3-append-id3v1-2',
            0,
            secondBytes,
            TtsAudioFormat.mp3,
            isLast: true,
          ),
        );

        final artifact = await output.finalizeSession() as FileAudioArtifact;
        final expected = Uint8List.fromList([
          ...firstBytes.sublist(0, firstBytes.length - 128),
          ...secondBytes,
        ]);

        expect(artifact.filePath, outputPath);
        expect(artifact.fileSizeBytes, expected.length);
        expect(await File(outputPath).readAsBytes(), expected);
      } finally {
        await tempDir.delete(recursive: true);
      }
    });

    test(
      'Mp3FileOutput rejects later sessions with mismatched metadata',
      () async {
        final tempDir = await Directory.systemTemp.createTemp(
          'uni_tts_mp3_mismatch_',
        );
        try {
          final outputPath =
              '${tempDir.path}${Platform.pathSeparator}mismatch.mp3';
          final output = Mp3FileOutput(outputPath);
          final baselineBytes = _mp3Bytes(
            frames: 1,
            version: Mp3MpegVersion.mpeg25,
            layer: Mp3Layer.layer3,
            sampleRateHz: 8000,
            channelMode: Mp3ChannelMode.mono,
          );
          final mismatchedBytes = _mp3Bytes(
            frames: 1,
            version: Mp3MpegVersion.mpeg1,
            layer: Mp3Layer.layer3,
            bitrateKbps: 32,
            sampleRateHz: 44100,
            channelMode: Mp3ChannelMode.mono,
          );

          await output.initSession(
            const TtsOutputSession(
              requestId: 'mp3-mismatch-1',
              audioSpec: _mp3Spec,
              voice: null,
              options: null,
            ),
          );
          await output.consumeChunk(
            _chunk(
              'mp3-mismatch-1',
              0,
              baselineBytes,
              TtsAudioFormat.mp3,
              isLast: true,
            ),
          );
          await output.finalizeSession();

          await output.initSession(
            const TtsOutputSession(
              requestId: 'mp3-mismatch-2',
              audioSpec: _mp3Spec,
              voice: null,
              options: null,
            ),
          );
          await output.consumeChunk(
            _chunk(
              'mp3-mismatch-2',
              0,
              mismatchedBytes,
              TtsAudioFormat.mp3,
              isLast: true,
            ),
          );

          await expectLater(
            output.finalizeSession(),
            throwsA(
              isA<TtsError>().having(
                (error) => error.code,
                'code',
                TtsErrorCode.invalidRequest,
              ),
            ),
          );

          expect(await File('$outputPath.tmp').exists(), isFalse);
          expect(await File(outputPath).readAsBytes(), baselineBytes);

          await output.initSession(
            const TtsOutputSession(
              requestId: 'mp3-mismatch-3',
              audioSpec: _mp3Spec,
              voice: null,
              options: null,
            ),
          );
          await output.consumeChunk(
            _chunk(
              'mp3-mismatch-3',
              0,
              baselineBytes,
              TtsAudioFormat.mp3,
              isLast: true,
            ),
          );
          final artifact = await output.finalizeSession() as FileAudioArtifact;
          expect(artifact.filePath, outputPath);
        } finally {
          await tempDir.delete(recursive: true);
        }
      },
    );

    test(
      'WavFileOutput clears temp and state after initSession failure',
      () async {
        final tempDir = await Directory.systemTemp.createTemp(
          'uni_tts_wav_finalize_fail_',
        );
        final outputPath =
            '${tempDir.path}${Platform.pathSeparator}finalize-fail.wav';
        final output = WavFileOutput(outputPath);
        try {
          const baselineDescriptor = PcmDescriptor(
            sampleRateHz: 24000,
            bitsPerSample: 16,
            channels: 1,
          );
          await output.initSession(
            const TtsOutputSession(
              requestId: 'wav-finalize-fail-0',
              audioSpec: TtsAudioSpec.pcm(baselineDescriptor),
              voice: null,
              options: null,
            ),
          );
          await output.consumeChunk(
            _pcmChunk(
              'wav-finalize-fail-0',
              0,
              [7, 8],
              baselineDescriptor,
              isLast: true,
            ),
          );
          await output.finalizeSession();

          const mismatchedDescriptor = PcmDescriptor(
            sampleRateHz: 16000,
            bitsPerSample: 16,
            channels: 1,
          );
          await expectLater(
            output.initSession(
              const TtsOutputSession(
                requestId: 'wav-finalize-fail-1',
                audioSpec: TtsAudioSpec.pcm(mismatchedDescriptor),
                voice: null,
                options: null,
              ),
            ),
            throwsA(
              isA<TtsError>().having(
                (error) => error.code,
                'code',
                TtsErrorCode.invalidRequest,
              ),
            ),
          );

          expect(await File('$outputPath.tmp').exists(), isFalse);

          await output.initSession(
            const TtsOutputSession(
              requestId: 'wav-finalize-fail-2',
              audioSpec: TtsAudioSpec.pcm(baselineDescriptor),
              voice: null,
              options: null,
            ),
          );
          await output.consumeChunk(
            _pcmChunk(
              'wav-finalize-fail-2',
              0,
              [1, 2, 3],
              baselineDescriptor,
              isLast: true,
            ),
          );
          final artifact = await output.finalizeSession() as FileAudioArtifact;
          expect(artifact.filePath, outputPath);
        } finally {
          await output.dispose();
          await tempDir.delete(recursive: true);
        }
      },
    );

    test('WavFileOutput onCancelSession removes temp file', () async {
      final tempDir = await Directory.systemTemp.createTemp(
        'uni_tts_wav_cancel_',
      );
      try {
        final outputPath = '${tempDir.path}${Platform.pathSeparator}cancel.wav';
        final output = WavFileOutput(outputPath);

        const descriptor = PcmDescriptor(
          sampleRateHz: 24000,
          bitsPerSample: 16,
          channels: 1,
        );
        const session = TtsOutputSession(
          requestId: 'wav-2',
          audioSpec: TtsAudioSpec.pcm(descriptor),
          voice: null,
          options: null,
        );

        await output.initSession(session);
        await output.consumeChunk(_pcmChunk('wav-2', 0, [5], descriptor));

        final control = SynthesisControl()
          ..cancel(CancelReason.stopCurrent, message: 'test-cancel');
        await output.onCancelSession(control);

        expect(await File('$outputPath.tmp').exists(), isFalse);
        expect(await File(outputPath).exists(), isFalse);
      } finally {
        await tempDir.delete(recursive: true);
      }
    });

    test('WavFileOutput accepts PCM chunks and produces WAV file', () async {
      final tempDir = await Directory.systemTemp.createTemp(
        'uni_tts_wav_from_pcm_',
      );
      try {
        final outputPath =
            '${tempDir.path}${Platform.pathSeparator}from-pcm.wav';
        final output = WavFileOutput(outputPath);
        const descriptor = PcmDescriptor(
          sampleRateHz: 22050,
          bitsPerSample: 16,
          channels: 1,
        );

        const session = TtsOutputSession(
          requestId: 'pcm-1',
          audioSpec: TtsAudioSpec.pcm(descriptor),
          voice: null,
          options: null,
        );

        await output.initSession(session);
        await output.consumeChunk(_pcmChunk('pcm-1', 0, [10, 11], descriptor));
        await output.consumeChunk(
          _pcmChunk('pcm-1', 1, [12, 13], descriptor, isLast: true),
        );

        final artifact = await output.finalizeSession() as FileAudioArtifact;
        expect(artifact.audioSpec.format, TtsAudioFormat.pcm);
        expect(artifact.filePath, outputPath);
        expect(artifact.fileSizeBytes, 48);

        final fileBytes = await File(outputPath).readAsBytes();
        final header = WavHeader.parse(fileBytes);
        expect(header.sampleRateHz, 22050);
        expect(header.bitsPerSample, 16);
        expect(header.channels, 1);
        expect(header.dataLengthBytes, 4);
        expect(fileBytes.sublist(44), [10, 11, 12, 13]);
      } finally {
        await tempDir.delete(recursive: true);
      }
    });

    test(
      'WavFileOutput appends across sessions with locked descriptor',
      () async {
        final tempDir = await Directory.systemTemp.createTemp(
          'uni_tts_wav_append_',
        );
        try {
          final outputPath =
              '${tempDir.path}${Platform.pathSeparator}append.wav';
          final output = WavFileOutput(outputPath);
          const descriptor = PcmDescriptor(
            sampleRateHz: 16000,
            bitsPerSample: 16,
            channels: 1,
          );

          await output.initSession(
            const TtsOutputSession(
              requestId: 'append-1',
              audioSpec: TtsAudioSpec.pcm(descriptor),
              voice: null,
              options: null,
            ),
          );
          await output.consumeChunk(
            _pcmChunk('append-1', 0, [1, 2], descriptor),
          );
          await output.finalizeSession();

          await output.initSession(
            const TtsOutputSession(
              requestId: 'append-2',
              audioSpec: TtsAudioSpec.pcm(descriptor),
              voice: null,
              options: null,
            ),
          );
          await output.consumeChunk(
            _pcmChunk('append-2', 0, [3, 4, 5], descriptor, isLast: true),
          );

          final artifact = await output.finalizeSession() as FileAudioArtifact;
          expect(artifact.audioSpec.format, TtsAudioFormat.pcm);
          expect(artifact.fileSizeBytes, 49);

          final fileBytes = await File(outputPath).readAsBytes();
          final header = WavHeader.parse(fileBytes);
          expect(header.sampleRateHz, 16000);
          expect(header.bitsPerSample, 16);
          expect(header.channels, 1);
          expect(header.dataLengthBytes, 5);
          expect(fileBytes.sublist(44), [1, 2, 3, 4, 5]);
        } finally {
          await tempDir.delete(recursive: true);
        }
      },
    );

    test(
      'WavFileOutput rejects later sessions with mismatched descriptor',
      () async {
        final tempDir = await Directory.systemTemp.createTemp(
          'uni_tts_wav_mismatch_',
        );
        try {
          final outputPath =
              '${tempDir.path}${Platform.pathSeparator}mismatch.wav';
          final output = WavFileOutput(outputPath);
          const lockedDescriptor = PcmDescriptor(
            sampleRateHz: 16000,
            bitsPerSample: 16,
            channels: 1,
          );
          const mismatchedDescriptor = PcmDescriptor(
            sampleRateHz: 22050,
            bitsPerSample: 16,
            channels: 1,
          );

          await output.initSession(
            const TtsOutputSession(
              requestId: 'mismatch-1',
              audioSpec: TtsAudioSpec.pcm(lockedDescriptor),
              voice: null,
              options: null,
            ),
          );
          await output.consumeChunk(
            _pcmChunk('mismatch-1', 0, [7, 8], lockedDescriptor, isLast: true),
          );
          await output.finalizeSession();

          final baselineBytes = await File(outputPath).readAsBytes();

          await expectLater(
            output.initSession(
              const TtsOutputSession(
                requestId: 'mismatch-2',
                audioSpec: TtsAudioSpec.pcm(mismatchedDescriptor),
                voice: null,
                options: null,
              ),
            ),
            throwsA(
              isA<TtsError>().having(
                (error) => error.code,
                'code',
                TtsErrorCode.invalidRequest,
              ),
            ),
          );

          expect(await File(outputPath).readAsBytes(), baselineBytes);
        } finally {
          await tempDir.delete(recursive: true);
        }
      },
    );

    test(
      'WavFileOutput cancel preserves previously accumulated file',
      () async {
        final tempDir = await Directory.systemTemp.createTemp(
          'uni_tts_wav_preserve_',
        );
        try {
          final outputPath =
              '${tempDir.path}${Platform.pathSeparator}preserve.wav';
          final output = WavFileOutput(outputPath);
          const descriptor = PcmDescriptor(
            sampleRateHz: 24000,
            bitsPerSample: 16,
            channels: 1,
          );

          await output.initSession(
            const TtsOutputSession(
              requestId: 'preserve-1',
              audioSpec: TtsAudioSpec.pcm(descriptor),
              voice: null,
              options: null,
            ),
          );
          await output.consumeChunk(
            _pcmChunk('preserve-1', 0, [9, 10], descriptor, isLast: true),
          );
          await output.finalizeSession();

          final baselineBytes = await File(outputPath).readAsBytes();

          await output.initSession(
            const TtsOutputSession(
              requestId: 'preserve-2',
              audioSpec: TtsAudioSpec.pcm(descriptor),
              voice: null,
              options: null,
            ),
          );
          await output.consumeChunk(
            _pcmChunk('preserve-2', 0, [11], descriptor),
          );

          final control = SynthesisControl()
            ..cancel(
              CancelReason.stopCurrent,
              message: 'cancel-second-session',
            );
          await output.onCancelSession(control);

          expect(await File('$outputPath.tmp').exists(), isFalse);
          expect(await File(outputPath).readAsBytes(), baselineBytes);
        } finally {
          await tempDir.delete(recursive: true);
        }
      },
    );

    test(
      'Mp3FileOutput cancel preserves previously accumulated file',
      () async {
        final tempDir = await Directory.systemTemp.createTemp(
          'uni_tts_mp3_preserve_',
        );
        try {
          final outputPath =
              '${tempDir.path}${Platform.pathSeparator}preserve.mp3';
          final output = Mp3FileOutput(outputPath);
          final baselineBytes = _mp3Bytes(frames: 1);
          final secondBytes = _mp3Bytes(frames: 1, bitrateKbps: 16);

          await output.initSession(
            const TtsOutputSession(
              requestId: 'mp3-preserve-1',
              audioSpec: _mp3Spec,
              voice: null,
              options: null,
            ),
          );
          await output.consumeChunk(
            _chunk('mp3-preserve-1', 0, baselineBytes, TtsAudioFormat.mp3),
          );
          await output.finalizeSession();

          final baselineFileBytes = await File(outputPath).readAsBytes();

          await output.initSession(
            const TtsOutputSession(
              requestId: 'mp3-preserve-2',
              audioSpec: _mp3Spec,
              voice: null,
              options: null,
            ),
          );
          await output.consumeChunk(
            _chunk('mp3-preserve-2', 0, secondBytes, TtsAudioFormat.mp3),
          );

          final control = SynthesisControl()
            ..cancel(
              CancelReason.stopCurrent,
              message: 'cancel-second-session',
            );
          await output.onCancelSession(control);

          expect(await File('$outputPath.tmp').exists(), isFalse);
          expect(await File(outputPath).readAsBytes(), baselineFileBytes);
        } finally {
          await tempDir.delete(recursive: true);
        }
      },
    );
  });

  group('M4 Multicast output', () {
    test('inAudioCapabilities intersects PCM constraints across children', () {
      final output = MulticastOutput(
        outputs: [
          _PcmConstraintOutput(outputId: 'pcm-16k', sampleRatesHz: {16000}),
          _PcmConstraintOutput(outputId: 'pcm-24k', sampleRatesHz: {24000}),
        ],
      );

      final capabilities = output.inAudioCapabilities;
      expect(capabilities, isEmpty);
    });

    test(
      'bestEffort finalizes successful outputs and records failures',
      () async {
        final output = MulticastOutput(
          outputs: [
            MemoryOutput(outputId: 'memory'),
            _FailingTestOutput(outputId: 'failing', failOnConsume: true),
          ],
          errorPolicy: MulticastOutputErrorPolicy.bestEffort,
        );

        const session = TtsOutputSession(
          requestId: 'Multicast-1',
          audioSpec: _pcmSpec,
          voice: null,
          options: null,
        );

        await output.initSession(session);
        await output.consumeChunk(
          _chunk('Multicast-1', 0, [1, 2, 3], TtsAudioFormat.pcm, isLast: true),
        );
        final artifact = await output.finalizeSession();

        expect(artifact, isA<MulticastAudioArtifact>());
        final multicast = artifact as MulticastAudioArtifact;
        expect(multicast.artifacts.keys, contains('memory'));
        expect(multicast.artifacts.keys, isNot(contains('failing')));
        expect(multicast.outputErrors.keys, contains('failing'));
      },
    );

    test('failFast throws TtsOutputFailure with output id', () async {
      final output = MulticastOutput(
        outputs: [
          MemoryOutput(outputId: 'memory'),
          _FailingTestOutput(outputId: 'failing', failOnConsume: true),
        ],
        errorPolicy: MulticastOutputErrorPolicy.failFast,
      );

      const session = TtsOutputSession(
        requestId: 'Multicast-2',
        audioSpec: _pcmSpec,
        voice: null,
        options: null,
      );

      await output.initSession(session);
      await expectLater(
        output.consumeChunk(
          _chunk('Multicast-2', 0, [5], TtsAudioFormat.pcm, isLast: true),
        ),
        throwsA(
          isA<TtsOutputFailure>().having(
            (failure) => failure.outputId,
            'outputId',
            'failing',
          ),
        ),
      );
    });

    test(
      'failFast initSession rolls back already initialized outputs',
      () async {
        final initializedThenRolledBack = _FailingTestOutput(
          outputId: 'initialized',
        );
        final failingInit = _FailingTestOutput(
          outputId: 'failing-init',
          failOnInit: true,
        );

        final output = MulticastOutput(
          outputs: [initializedThenRolledBack, failingInit],
          errorPolicy: MulticastOutputErrorPolicy.failFast,
        );

        const session = TtsOutputSession(
          requestId: 'Multicast-init-rollback',
          audioSpec: _pcmSpec,
          voice: null,
          options: null,
        );

        await expectLater(
          output.initSession(session),
          throwsA(
            isA<TtsOutputFailure>().having(
              (failure) => failure.outputId,
              'outputId',
              'failing-init',
            ),
          ),
        );

        expect(initializedThenRolledBack.cancelCalls, 1);
      },
    );

    test('failFast finalize rolls back remaining outputs', () async {
      final successfulThenRolledBack = _FailingTestOutput(
        outputId: 'successful',
      );
      final failingFinalize = _FailingTestOutput(
        outputId: 'failing-finalize',
        failOnFinalize: true,
      );

      final output = MulticastOutput(
        outputs: [successfulThenRolledBack, failingFinalize],
        errorPolicy: MulticastOutputErrorPolicy.failFast,
      );

      const session = TtsOutputSession(
        requestId: 'Multicast-finalize-rollback',
        audioSpec: _pcmSpec,
        voice: null,
        options: null,
      );

      await output.initSession(session);
      await output.consumeChunk(
        _chunk(
          'Multicast-finalize-rollback',
          0,
          [1],
          TtsAudioFormat.pcm,
          isLast: true,
        ),
      );

      await expectLater(
        output.finalizeSession(),
        throwsA(
          isA<TtsOutputFailure>().having(
            (failure) => failure.outputId,
            'outputId',
            'failing-finalize',
          ),
        ),
      );

      expect(successfulThenRolledBack.cancelCalls, 1);
    });
  });
}

final class _FailingTestOutput implements TtsOutput {
  _FailingTestOutput({
    required this.outputId,
    this.failOnInit = false,
    this.failOnConsume = false,
    this.failOnFinalize = false,
  });

  @override
  final String outputId;
  final bool failOnInit;
  final bool failOnConsume;
  final bool failOnFinalize;
  int cancelCalls = 0;
  TtsOutputSession? _session;

  @override
  Set<AudioCapability> get inAudioCapabilities => {PcmCapability.wav()};

  @override
  Future<void> consumeChunk(TtsChunk chunk) async {
    if (failOnConsume) {
      throw const TtsError(
        code: TtsErrorCode.outputWriteFailed,
        message: 'Injected consume failure.',
      );
    }
  }

  @override
  Future<void> dispose() async {}

  @override
  Future<AudioArtifact> finalizeSession() async {
    if (failOnFinalize) {
      throw const TtsError(
        code: TtsErrorCode.outputWriteFailed,
        message: 'Injected finalize failure.',
      );
    }
    final session = _session;
    if (session == null) {
      throw StateError('No active output session.');
    }
    return InMemoryAudioArtifact(
      requestId: session.requestId,
      audioSpec: session.audioSpec,
      audioBytes: Uint8List(0),
      totalBytes: 0,
    );
  }

  @override
  Future<void> init() async {}

  @override
  Future<void> initSession(TtsOutputSession session) async {
    if (failOnInit) {
      throw const TtsError(
        code: TtsErrorCode.outputWriteFailed,
        message: 'Injected init failure.',
      );
    }
    _session = session;
  }

  @override
  Future<void> onCancelSession(SynthesisControl control) async {
    cancelCalls += 1;
    _session = null;
  }
}

final class _PcmConstraintOutput implements TtsOutput {
  _PcmConstraintOutput({
    required this.outputId,
    required Set<int> sampleRatesHz,
  }) : _sampleRatesHz = Set<int>.from(sampleRatesHz);

  @override
  final String outputId;

  final Set<int> _sampleRatesHz;

  @override
  Set<AudioCapability> get inAudioCapabilities => {
    PcmCapability(
      sampleRatesHz: _sampleRatesHz,
      bitsPerSample: const {16},
      channels: const {1},
      encodings: const {PcmEncoding.signedInt},
    ),
  };

  @override
  Future<void> consumeChunk(TtsChunk chunk) async {}

  @override
  Future<void> dispose() async {}

  @override
  Future<AudioArtifact> finalizeSession() async {
    throw UnimplementedError();
  }

  @override
  Future<void> init() async {}

  @override
  Future<void> initSession(TtsOutputSession session) async {}

  @override
  Future<void> onCancelSession(SynthesisControl control) async {}
}

TtsChunk _chunk(
  String requestId,
  int seq,
  List<int> bytes,
  TtsAudioFormat format, {
  bool isLast = false,
}) {
  return TtsAudioChunk(
    requestId: requestId,
    sequenceNumber: seq,
    bytes: Uint8List.fromList(bytes),
    audioSpec: _audioSpecForFormat(format),
    isLastChunk: isLast,
    timestamp: DateTime.now().toUtc(),
  );
}

TtsAudioSpec _audioSpecForFormat(TtsAudioFormat format) {
  switch (format) {
    case TtsAudioFormat.pcm:
      return _pcmSpec;
    case TtsAudioFormat.mp3:
      return _mp3Spec;
    case TtsAudioFormat.opus:
      return const TtsAudioSpec.opus();
    case TtsAudioFormat.aac:
      return const TtsAudioSpec.aac();
  }
}

TtsChunk _pcmChunk(
  String requestId,
  int seq,
  List<int> bytes,
  PcmDescriptor descriptor, {
  bool isLast = false,
}) {
  return TtsAudioChunk(
    requestId: requestId,
    sequenceNumber: seq,
    bytes: Uint8List.fromList(bytes),
    audioSpec: TtsAudioSpec.pcm(descriptor),
    isLastChunk: isLast,
    timestamp: DateTime.now().toUtc(),
  );
}

Uint8List _mp3Bytes({
  int frames = 1,
  bool includeId3v2Tag = false,
  bool includeId3v1Tag = false,
  Mp3MpegVersion version = Mp3MpegVersion.mpeg25,
  Mp3Layer layer = Mp3Layer.layer3,
  int bitrateKbps = 8,
  int sampleRateHz = 8000,
  Mp3ChannelMode channelMode = Mp3ChannelMode.stereo,
}) {
  final singleFrame = _mp3Frame(
    version: version,
    layer: layer,
    bitrateKbps: bitrateKbps,
    sampleRateHz: sampleRateHz,
    channelMode: channelMode,
  );
  final tagLength = includeId3v2Tag ? 10 : 0;
  final trailerLength = includeId3v1Tag ? 128 : 0;
  final audioLength = singleFrame.length * frames;
  final bytes = Uint8List(tagLength + audioLength + trailerLength);

  if (includeId3v2Tag) {
    bytes[0] = 0x49;
    bytes[1] = 0x44;
    bytes[2] = 0x33;
    bytes[3] = 0x04;
    bytes[4] = 0x00;
    bytes[5] = 0x00;
    bytes[6] = 0x00;
    bytes[7] = 0x00;
    bytes[8] = 0x00;
    bytes[9] = 0x00;
  }

  for (var index = 0; index < frames; index++) {
    final start = tagLength + (index * singleFrame.length);
    bytes.setRange(start, start + singleFrame.length, singleFrame);
  }

  if (includeId3v1Tag) {
    final trailerStart = tagLength + audioLength;
    bytes[trailerStart] = 0x54;
    bytes[trailerStart + 1] = 0x41;
    bytes[trailerStart + 2] = 0x47;
  }

  return bytes;
}

Uint8List _mp3Frame({
  required Mp3MpegVersion version,
  required Mp3Layer layer,
  required int bitrateKbps,
  required int sampleRateHz,
  required Mp3ChannelMode channelMode,
}) {
  final versionBits = switch (version) {
    Mp3MpegVersion.mpeg25 => 0,
    Mp3MpegVersion.mpeg2 => 2,
    Mp3MpegVersion.mpeg1 => 3,
  };
  final layerBits = switch (layer) {
    Mp3Layer.layer3 => 1,
    Mp3Layer.layer2 => 2,
    Mp3Layer.layer1 => 3,
  };
  final bitrateIndex = _bitrateIndexFor(
    version: version,
    layer: layer,
    bitrateKbps: bitrateKbps,
  );
  final sampleRateIndex = _sampleRateIndexFor(
    version: version,
    sampleRateHz: sampleRateHz,
  );
  final channelModeBits = channelMode.index;

  var rawHeader = 0xFFE00000;
  rawHeader |= versionBits << 19;
  rawHeader |= layerBits << 17;
  rawHeader |= 1 << 16;
  rawHeader |= bitrateIndex << 12;
  rawHeader |= sampleRateIndex << 10;
  rawHeader |= channelModeBits << 6;

  final headerBytes = Uint8List(4);
  final headerData = ByteData.sublistView(headerBytes);
  headerData.setUint32(0, rawHeader, Endian.big);

  final header = Mp3FrameHeader.parse(headerBytes);
  final frameBytes = Uint8List(header.frameLengthBytes)
    ..setRange(0, 4, headerBytes);
  for (var index = 4; index < frameBytes.length; index++) {
    frameBytes[index] = index & 0xFF;
  }
  return frameBytes;
}

int _bitrateIndexFor({
  required Mp3MpegVersion version,
  required Mp3Layer layer,
  required int bitrateKbps,
}) {
  final values = switch ((version, layer)) {
    (Mp3MpegVersion.mpeg1, Mp3Layer.layer1) => const [
      32,
      64,
      96,
      128,
      160,
      192,
      224,
      256,
      288,
      320,
      352,
      384,
      416,
      448,
    ],
    (Mp3MpegVersion.mpeg1, Mp3Layer.layer2) => const [
      32,
      48,
      56,
      64,
      80,
      96,
      112,
      128,
      160,
      192,
      224,
      256,
      320,
      384,
    ],
    (Mp3MpegVersion.mpeg1, Mp3Layer.layer3) => const [
      32,
      40,
      48,
      56,
      64,
      80,
      96,
      112,
      128,
      160,
      192,
      224,
      256,
      320,
    ],
    (_, Mp3Layer.layer1) => const [
      32,
      48,
      56,
      64,
      80,
      96,
      112,
      128,
      144,
      160,
      176,
      192,
      224,
      256,
    ],
    _ => const [8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160],
  };

  final index = values.indexOf(bitrateKbps);
  if (index == -1) {
    throw ArgumentError.value(
      bitrateKbps,
      'bitrateKbps',
      'Unsupported bitrate for $version/$layer.',
    );
  }
  return index + 1;
}

int _sampleRateIndexFor({
  required Mp3MpegVersion version,
  required int sampleRateHz,
}) {
  final values = switch (version) {
    Mp3MpegVersion.mpeg1 => const [44100, 48000, 32000],
    Mp3MpegVersion.mpeg2 => const [22050, 24000, 16000],
    Mp3MpegVersion.mpeg25 => const [11025, 12000, 8000],
  };

  final index = values.indexOf(sampleRateHz);
  if (index == -1) {
    throw ArgumentError.value(
      sampleRateHz,
      'sampleRateHz',
      'Unsupported sample rate for $version.',
    );
  }
  return index;
}
