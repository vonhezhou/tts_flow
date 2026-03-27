import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
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
  group('M3 format negotiator', () {
    const negotiator = TtsFormatNegotiator();

    test('negotiates PCM descriptor honoring preferred sample rate', () {
      final resolved = negotiator.negotiateSpec(
        engineCapabilities: {
          PcmCapability(
            sampleRatesHz: {16000, 24000, 48000},
            bitsPerSample: {16},
            channels: {1},
            encodings: {PcmEncoding.signedInt},
          ),
        },
        outputCapabilities: {
          PcmCapability(
            sampleRatesHz: {22050, 24000},
            bitsPerSample: {16},
            channels: {1},
            encodings: {PcmEncoding.signedInt},
          ),
        },
        preferredOrder: const [TtsAudioFormat.pcm],
        requestId: 'n0',
        preferredSampleRateHz: 24000,
      );

      expect(resolved.format, TtsAudioFormat.pcm);
      expect(resolved.requirePcm.sampleRateHz, 24000);
      expect(resolved.requirePcm.bitsPerSample, 16);
      expect(resolved.requirePcm.channels, 1);
    });

    test('negotiates PCM fallback sample rate when preferred not available',
        () {
      final resolved = negotiator.negotiateSpec(
        engineCapabilities: {
          PcmCapability(
            sampleRatesHz: {16000, 22050},
            bitsPerSample: {16},
            channels: {1},
            encodings: {PcmEncoding.signedInt},
          ),
        },
        outputCapabilities: {
          PcmCapability(
            sampleRatesHz: {8000, 16000, 22050},
            bitsPerSample: {16},
            channels: {1},
            encodings: {PcmEncoding.signedInt},
          ),
        },
        preferredOrder: const [TtsAudioFormat.pcm],
        requestId: 'n0b',
        preferredSampleRateHz: 24000,
      );

      expect(resolved.format, TtsAudioFormat.pcm);
      expect(resolved.requirePcm.sampleRateHz, 22050);
    });

    test('negotiates PCM using discrete-vs-range sample-rate constraints', () {
      final resolved = negotiator.negotiateSpec(
        engineCapabilities: {
          PcmCapability(
            sampleRatesHz: {16000, 24000, 48000},
            bitsPerSample: {16},
            channels: {1},
            encodings: {PcmEncoding.signedInt},
          ),
        },
        outputCapabilities: {
          PcmCapability(
            sampleRatesHz: null,
            bitsPerSample: {16},
            channels: {1},
            encodings: {PcmEncoding.signedInt},
          ),
        },
        preferredOrder: const [TtsAudioFormat.pcm],
        requestId: 'n0c',
      );

      expect(resolved.format, TtsAudioFormat.pcm);
      expect(resolved.requirePcm.sampleRateHz, 48000);
    });

    test('negotiates PCM using WAV full sample-rate range', () {
      final resolved = negotiator.negotiateSpec(
        engineCapabilities: {
          PcmCapability.wav(),
        },
        outputCapabilities: {
          PcmCapability(
            sampleRatesHz: {8000, 22050, 24000},
            bitsPerSample: {16},
            channels: {1},
            encodings: {PcmEncoding.signedInt},
          ),
        },
        preferredOrder: const [TtsAudioFormat.pcm],
        requestId: 'n0d',
        preferredSampleRateHz: 22050,
      );

      expect(resolved.format, TtsAudioFormat.pcm);
      expect(resolved.requirePcm.sampleRateHz, 22050);
    });

    test('negotiates PCM using discrete-vs-range bit-depth constraints', () {
      final resolved = negotiator.negotiateSpec(
        engineCapabilities: {
          PcmCapability(
            sampleRatesHz: {24000},
            bitsPerSample: {16, 24, 32},
            channels: {1},
            encodings: {PcmEncoding.signedInt},
          ),
        },
        outputCapabilities: {
          PcmCapability(
            sampleRatesHz: {24000},
            bitsPerSample: null,
            channels: {1},
            encodings: {PcmEncoding.signedInt},
          ),
        },
        preferredOrder: const [TtsAudioFormat.pcm],
        requestId: 'n0e',
      );

      expect(resolved.format, TtsAudioFormat.pcm);
      expect(resolved.requirePcm.bitsPerSample, 32);
    });

    test('negotiates PCM using discrete-vs-range channel constraints', () {
      final resolved = negotiator.negotiateSpec(
        engineCapabilities: {
          PcmCapability(
            sampleRatesHz: {24000},
            bitsPerSample: {16},
            channels: {1, 2},
            encodings: {PcmEncoding.signedInt},
          ),
        },
        outputCapabilities: {
          PcmCapability(
            sampleRatesHz: {24000},
            bitsPerSample: {16},
            channels: {2},
            encodings: {PcmEncoding.signedInt},
          ),
        },
        preferredOrder: const [TtsAudioFormat.pcm],
        requestId: 'n0f',
      );

      expect(resolved.format, TtsAudioFormat.pcm);
      expect(resolved.requirePcm.channels, 2);
    });

    test('uses request preferred format when available', () {
      final resolved = negotiator.negotiate(
        engineFormats: {TtsAudioFormat.mp3, TtsAudioFormat.pcm},
        outputFormats: {TtsAudioFormat.mp3},
        preferredOrder: const [TtsAudioFormat.pcm, TtsAudioFormat.mp3],
        requestId: 'n1',
        preferredFormat: TtsAudioFormat.mp3,
      );

      expect(resolved, TtsAudioFormat.mp3);
    });

    test('uses deterministic fallback order when preferred not available', () {
      final resolved = negotiator.negotiate(
        engineFormats: {TtsAudioFormat.aac, TtsAudioFormat.mp3},
        outputFormats: {TtsAudioFormat.aac, TtsAudioFormat.mp3},
        preferredOrder: const [TtsAudioFormat.pcm, TtsAudioFormat.aac],
        requestId: 'n2',
      );

      expect(resolved, TtsAudioFormat.aac);
    });

    test('throws formatNegotiationFailed when intersection is empty', () {
      expect(
        () => negotiator.negotiate(
          engineFormats: {TtsAudioFormat.mp3},
          outputFormats: {TtsAudioFormat.pcm},
          preferredOrder: const [TtsAudioFormat.pcm],
          requestId: 'n3',
        ),
        throwsA(
          isA<TtsError>().having(
            (error) => error.code,
            'code',
            TtsErrorCode.formatNegotiationFailed,
          ),
        ),
      );
    });

    test('includes capability context when no shared format exists', () {
      try {
        negotiator.negotiateSpec(
          engineCapabilities: {
            const Mp3Capability(),
          },
          outputCapabilities: {
            PcmCapability(),
          },
          preferredOrder: const [TtsAudioFormat.pcm],
          requestId: 'n4',
          preferredFormat: TtsAudioFormat.pcm,
        );
        fail('Expected TtsError to be thrown.');
      } on TtsError catch (error) {
        expect(error.code, TtsErrorCode.formatNegotiationFailed);
        expect(error.message, contains('engineFormats'));
        expect(error.message, contains('outputFormats'));
        expect(error.message, contains('preferredOrder'));
      }
    });

    test('includes PCM capability context when descriptor mismatch occurs', () {
      try {
        negotiator.negotiateSpec(
          engineCapabilities: {
            PcmCapability(
              sampleRatesHz: {16000},
              bitsPerSample: {16},
              channels: {1},
              encodings: {PcmEncoding.signedInt},
            ),
          },
          outputCapabilities: {
            PcmCapability(
              sampleRatesHz: {24000},
              bitsPerSample: {16},
              channels: {1},
              encodings: {PcmEncoding.signedInt},
            ),
          },
          preferredOrder: const [TtsAudioFormat.pcm],
          requestId: 'n5',
          preferredSampleRateHz: 24000,
        );
        fail('Expected TtsError to be thrown.');
      } on TtsError catch (error) {
        expect(error.code, TtsErrorCode.formatNegotiationFailed);
        expect(error.message, contains('preferredSampleRateHz: 24000'));
        expect(error.message, contains('enginePcmCapabilities'));
        expect(error.message, contains('outputPcmCapabilities'));
      }
    });
  });

  group('M3 file engine adapter', () {
    test('always returns provided content for any request text', () async {
      final payload = Uint8List.fromList(utf8.encode('fixed-audio-content'));
      final engine = FileTtsEngine(
        engineId: 'file-engine',
        provider: RawBytesContentProvider(
          bytes: payload,
          audioSpec: _mp3Spec,
        ),
        chunkSizeBytes: 5,
      );
      final control = SynthesisControl();

      final chunks = await engine
          .synthesize(
            const TtsRequest(requestId: 'fx1', text: 'this should be ignored'),
            control,
            _mp3Spec,
          )
          .toList();

      final reconstructed = Uint8List.fromList(
        chunks.expand((chunk) => chunk.bytes).toList(growable: false),
      );

      expect(reconstructed, payload);
      expect(chunks.last.isLastChunk, isTrue);
      expect(chunks.every((chunk) => chunk.requestId == 'fx1'), isTrue);
    });

    test('limits send speed when maxBytesPerSecond is set', () async {
      final payload =
          Uint8List.fromList(List<int>.generate(300, (i) => i % 251));
      final engine = FileTtsEngine(
        engineId: 'file-engine-throttle',
        provider: RawBytesContentProvider(
          bytes: payload,
          audioSpec: _mp3Spec,
        ),
        chunkSizeBytes: 100,
        maxBytesPerSecond: 1000,
      );
      final control = SynthesisControl();
      final stopwatch = Stopwatch()..start();

      final chunks = await engine
          .synthesize(
            const TtsRequest(requestId: 'fx2', text: 'ignored too'),
            control,
            _mp3Spec,
          )
          .toList();

      stopwatch.stop();

      expect(chunks, hasLength(3));
      expect(stopwatch.elapsedMilliseconds, greaterThanOrEqualTo(220));
    });

    test('throws unsupportedFormat when resolved format is not supported',
        () async {
      final engine = FileTtsEngine(
        engineId: 'file-engine-format-guard',
        provider: RawBytesContentProvider(
          bytes: Uint8List.fromList([1, 2, 3]),
          audioSpec: _mp3Spec,
        ),
      );

      await expectLater(
        engine
            .synthesize(
              const TtsRequest(requestId: 'fx3', text: 'ignored'),
              SynthesisControl(),
              _pcmSpec,
            )
            .drain(),
        throwsA(
          isA<TtsError>().having(
            (error) => error.code,
            'code',
            TtsErrorCode.unsupportedFormat,
          ),
        ),
      );
    });

    test('stops streaming quickly after cancellation', () async {
      final payload =
          Uint8List.fromList(List<int>.generate(600, (index) => index % 255));
      final engine = FileTtsEngine(
        engineId: 'file-engine-cancel',
        provider: RawBytesContentProvider(
          bytes: payload,
          audioSpec: _mp3Spec,
        ),
        chunkSizeBytes: 100,
        maxBytesPerSecond: 1200,
      );
      final control = SynthesisControl();
      final stopwatch = Stopwatch()..start();
      final received = <TtsChunk>[];
      final done = Completer<void>();

      engine
          .synthesize(
        const TtsRequest(requestId: 'fx4', text: 'ignored too'),
        control,
        _mp3Spec,
      )
          .listen(
        (chunk) {
          received.add(chunk);
          if (received.length == 1) {
            control.cancel(CancelReason.stopCurrent, message: 'test cancel');
          }
        },
        onDone: () => done.complete(),
        onError: done.completeError,
      );

      await done.future;
      stopwatch.stop();

      expect(received, hasLength(1));
      expect(received.single.isLastChunk, isFalse);
      expect(stopwatch.elapsedMilliseconds, lessThan(700));
    });
  });

  group('M3 MP3 file content provider', () {
    test('strips ID3v2 header bytes before streaming audio', () async {
      final tempDir = await Directory.systemTemp.createTemp('tts-mp3-id3v2-');
      try {
        final file = File('${tempDir.path}/sample.mp3');
        final id3Header = Uint8List.fromList([
          0x49,
          0x44,
          0x33,
          0x04,
          0x00,
          0x00,
          0x00,
          0x00,
          0x00,
          0x00,
        ]);
        final audioPayload = Uint8List.fromList([0xFF, 0xFB, 0x90, 0x64, 1, 2]);
        await file.writeAsBytes([...id3Header, ...audioPayload]);

        final provider = Mp3FileContentProvider(file.path);
        final chunks = await provider.readChunks(4).toList();
        final streamed = Uint8List.fromList(
          chunks.expand((chunk) => chunk).toList(growable: false),
        );

        expect(streamed, audioPayload);
      } finally {
        await tempDir.delete(recursive: true);
      }
    });

    test('strips ID3v1 footer bytes from stream tail', () async {
      final tempDir = await Directory.systemTemp.createTemp('tts-mp3-id3v1-');
      try {
        final file = File('${tempDir.path}/sample.mp3');
        final audioPayload = Uint8List.fromList([0xFF, 0xFB, 0x90, 0x64, 1, 2]);
        final footer = Uint8List(128)
          ..[0] = 0x54
          ..[1] = 0x41
          ..[2] = 0x47;
        await file.writeAsBytes([...audioPayload, ...footer]);

        final provider = Mp3FileContentProvider(file.path);
        final chunks = await provider.readChunks(4).toList();
        final streamed = Uint8List.fromList(
          chunks.expand((chunk) => chunk).toList(growable: false),
        );

        expect(streamed, audioPayload);
      } finally {
        await tempDir.delete(recursive: true);
      }
    });

    test('returns empty stream for empty file', () async {
      final tempDir = await Directory.systemTemp.createTemp('tts-mp3-empty-');
      try {
        final file = File('${tempDir.path}/empty.mp3');
        await file.writeAsBytes(const []);

        final provider = Mp3FileContentProvider(file.path);
        final chunks = await provider.readChunks(16).toList();

        expect(chunks, isEmpty);
      } finally {
        await tempDir.delete(recursive: true);
      }
    });

    test('throws format error when no MPEG frame exists after stripping',
        () async {
      final tempDir =
          await Directory.systemTemp.createTemp('tts-mp3-invalid-data-');
      try {
        final file = File('${tempDir.path}/invalid.mp3');
        final id3Header = Uint8List.fromList([
          0x49,
          0x44,
          0x33,
          0x04,
          0x00,
          0x00,
          0x00,
          0x00,
          0x00,
          0x00,
        ]);
        final invalidAudioPayload = Uint8List.fromList([0, 1, 2, 3, 4, 5]);
        await file.writeAsBytes([...id3Header, ...invalidAudioPayload]);

        final provider = Mp3FileContentProvider(file.path);

        await expectLater(
          provider.readChunks(4).drain(),
          throwsA(isA<FormatException>()),
        );
      } finally {
        await tempDir.delete(recursive: true);
      }
    });
  });

  group('M3 WAV file content provider', () {
    test('fromWav returns raw PCM chunks', () async {
      final tempDir = await Directory.systemTemp.createTemp('tts-wav-file-');
      try {
        final file = File('${tempDir.path}/sample.wav');
        final pcm = Uint8List.fromList([1, 2, 3, 4, 5, 6]);
        final descriptor = const PcmDescriptor(
          sampleRateHz: 24000,
          bitsPerSample: 16,
          channels: 1,
        );
        final sourceHeader = WavHeader.fromPcmDescriptor(
          descriptor,
          dataLengthBytes: pcm.length,
        ).toBytes();
        await file.writeAsBytes([...sourceHeader, ...pcm]);

        final provider = WavFileContentProvider.fromWav(file.path);
        final chunks = await provider.readChunks(4).toList();

        expect(chunks, hasLength(2));
        expect(provider.audioSpec.format, TtsAudioFormat.pcm);
        expect(chunks[0], [1, 2, 3, 4]);
        expect(chunks[1], [5, 6]);
      } finally {
        await tempDir.delete(recursive: true);
      }
    });

    test('fromPcm returns raw PCM bytes', () async {
      final tempDir = await Directory.systemTemp.createTemp('tts-wav-pcm-');
      try {
        final file = File('${tempDir.path}/sample.pcm');
        final pcm = Uint8List.fromList([10, 20, 30, 40, 50]);
        await file.writeAsBytes(pcm);

        final descriptor = const PcmDescriptor(
          sampleRateHz: 16000,
          bitsPerSample: 16,
          channels: 1,
        );
        final provider = WavFileContentProvider.fromPcm(file.path, descriptor);
        final chunks = await provider.readChunks(3).toList();

        expect(chunks, hasLength(2));
        expect(provider.audioSpec.format, TtsAudioFormat.pcm);
        expect(chunks[0], [10, 20, 30]);
        expect(chunks[1], [40, 50]);
      } finally {
        await tempDir.delete(recursive: true);
      }
    });

    test('fromPcm streams chunked raw PCM consistently', () async {
      final tempDir = await Directory.systemTemp.createTemp('tts-pcm-raw-out-');
      try {
        final file = File('${tempDir.path}/sample.pcm');
        final pcm = Uint8List.fromList([21, 22, 23, 24, 25]);
        await file.writeAsBytes(pcm);

        final provider = WavFileContentProvider.fromPcm(
          file.path,
          const PcmDescriptor(
            sampleRateHz: 16000,
            bitsPerSample: 16,
            channels: 1,
          ),
        );
        final chunks = await provider.readChunks(2).toList();

        expect(provider.audioSpec.format, TtsAudioFormat.pcm);
        expect(chunks, hasLength(3));
        expect(chunks[0], [21, 22]);
        expect(chunks[1], [23, 24]);
        expect(chunks[2], [25]);
      } finally {
        await tempDir.delete(recursive: true);
      }
    });

    test('fromWav exposes descriptor immediately via audioSpec', () async {
      final tempDir = await Directory.systemTemp.createTemp('tts-wav-spec-');
      try {
        final file = File('${tempDir.path}/spec.wav');
        final descriptor = const PcmDescriptor(
          sampleRateHz: 44100,
          bitsPerSample: 16,
          channels: 2,
        );
        final bytes = WavHeader.fromPcmDescriptor(
          descriptor,
          dataLengthBytes: 4,
        ).toBytes();
        await file.writeAsBytes([...bytes, 1, 2, 3, 4]);

        final provider = WavFileContentProvider.fromWav(file.path);
        final resolved = provider.audioSpec.pcm;

        expect(resolved, isNotNull);
        expect(resolved!.sampleRateHz, 44100);
        expect(resolved.channels, 2);
      } finally {
        await tempDir.delete(recursive: true);
      }
    });

    test('fromWav throws when header is too short', () async {
      final tempDir =
          await Directory.systemTemp.createTemp('tts-wav-short-header-');
      try {
        final file = File('${tempDir.path}/short.wav');
        await file.writeAsBytes([1, 2, 3, 4]);

        expect(
          () => WavFileContentProvider.fromWav(file.path),
          throwsA(isA<FormatException>()),
        );
      } finally {
        await tempDir.delete(recursive: true);
      }
    });

    test('fromWav throws when bytes are not a WAV header', () async {
      final tempDir =
          await Directory.systemTemp.createTemp('tts-wav-invalid-header-');
      try {
        final file = File('${tempDir.path}/invalid.wav');
        await file.writeAsBytes(List<int>.filled(44, 0));

        expect(
          () => WavFileContentProvider.fromWav(file.path),
          throwsA(isA<FormatException>()),
        );
      } finally {
        await tempDir.delete(recursive: true);
      }
    });
  });

  group('M3 OpenAI engine adapter', () {
    test('reports catalog voices for the configured model', () async {
      final engine = OpenAiTtsEngine(
        apiClient: _SuccessApiClient(),
        model: 'gpt-4o-mini-tts',
      );

      final voices = await engine.getAvailableVoices();
      final defaultVoice = await engine.getDefaultVoice();

      expect(voices, hasLength(11));
      expect(
        voices.map((v) => v.voiceId),
        containsAll(['alloy', 'ash', 'ballad', 'coral', 'echo']),
      );
      expect(defaultVoice.voiceId, 'alloy');
      expect(defaultVoice.isDefault, isTrue);
    });

    test('uses built-in catalog scoped to tts-1 model', () async {
      final engine = OpenAiTtsEngine(
        apiClient: _SuccessApiClient(),
        model: 'tts-1',
      );

      final voices = await engine.getAvailableVoices();

      expect(voices, hasLength(6));
      expect(
        voices.map((v) => v.voiceId),
        containsAll(['alloy', 'nova', 'shimmer']),
      );
    });

    test('per-model override replaces built-in catalog for that model',
        () async {
      const customVoices = [
        TtsVoice(voiceId: 'custom-1'),
        TtsVoice(voiceId: 'custom-2'),
      ];
      final engine = OpenAiTtsEngine(
        apiClient: _SuccessApiClient(),
        model: 'tts-1',
        voiceCatalogOverrides: {'tts-1': customVoices},
      );

      final voices = await engine.getAvailableVoices();

      expect(voices, hasLength(2));
      expect(
          voices.map((v) => v.voiceId), containsAll(['custom-1', 'custom-2']));
    });

    test('unknown model falls back to generic voice list', () async {
      final engine = OpenAiTtsEngine(
        apiClient: _SuccessApiClient(),
        model: 'unknown-model-xyz',
      );

      final voices = await engine.getAvailableVoices();

      expect(voices, isNotEmpty);
      expect(voices.any((v) => v.isDefault), isTrue);
    });

    test('resolves default voice for locale using per-model override',
        () async {
      final engine = OpenAiTtsEngine(
        apiClient: _SuccessApiClient(),
        model: 'tts-1',
        voiceCatalogOverrides: {
          'tts-1': const [
            TtsVoice(voiceId: 'en-voice', locale: 'en-US', isDefault: true),
            TtsVoice(voiceId: 'es-voice', locale: 'es-ES'),
          ],
        },
      );

      final localeDefault = await engine.getDefaultVoiceForLocale('es-ES');
      final fallbackDefault = await engine.getDefaultVoiceForLocale('fr-FR');

      expect(localeDefault.voiceId, 'es-voice');
      expect(fallbackDefault.voiceId, 'en-voice');
    });

    test('adapts streaming response into ordered chunks', () async {
      final engine = OpenAiTtsEngine(
        apiClient: _SuccessApiClient(
          streamChunks: const [
            [0, 1, 2, 3],
            [4, 5, 6],
            [7, 8, 9],
          ],
        ),
      );

      final chunks = await engine
          .synthesize(
            const TtsRequest(requestId: 'o1', text: 'hello'),
            SynthesisControl(),
            _mp3Spec,
          )
          .toList();

      expect(chunks, hasLength(3));
      expect(chunks[0].sequenceNumber, 0);
      expect(chunks[1].sequenceNumber, 1);
      expect(chunks[2].sequenceNumber, 2);
      expect(chunks[0].bytes, Uint8List.fromList([0, 1, 2, 3]));
      expect(chunks[1].bytes, Uint8List.fromList([4, 5, 6]));
      expect(chunks[2].bytes, Uint8List.fromList([7, 8, 9]));
      expect(chunks[2].isLastChunk, isTrue);
      expect(
        chunks.every((chunk) => chunk.audioSpec.format == TtsAudioFormat.mp3),
        isTrue,
      );
    });

    test('maps transport auth error to authFailed', () async {
      final engine = OpenAiTtsEngine(
        apiClient: const _FailApiClient(
          OpenAiTransportException(statusCode: 401, message: 'unauthorized'),
        ),
      );

      await expectLater(
        engine
            .synthesize(
              const TtsRequest(requestId: 'o2', text: 'hello'),
              SynthesisControl(),
              _mp3Spec,
            )
            .toList(),
        throwsA(
          isA<TtsError>().having(
            (error) => error.code,
            'code',
            TtsErrorCode.authFailed,
          ),
        ),
      );
    });

    test('retrying api client retries retryable failure then succeeds',
        () async {
      var attempts = 0;
      final apiClient = OpenAiRetryingApiClient(
        inner: _CallbackApiClient(() async {
          attempts++;
          if (attempts < 2) {
            throw const OpenAiTransportException(
              statusCode: 500,
              message: 'server',
            );
          }
          return _streamedResponse(
            const [
              [1, 2],
            ],
          );
        }),
        maxRetries: 2,
        initialBackoff: const Duration(milliseconds: 1),
      );

      final response = await apiClient.send(
        OpenAiApiRequest.json(body: '{"input":"hi"}'),
      );
      final chunks = await response.stream.toList();

      expect(attempts, 2);
      expect(chunks, const [
        [1, 2],
      ]);
    });

    test('retrying api client does not retry auth failure', () async {
      var attempts = 0;
      final apiClient = OpenAiRetryingApiClient(
        inner: _CallbackApiClient(() async {
          attempts++;
          throw const OpenAiTransportException(
            statusCode: 401,
            message: 'unauthorized',
          );
        }),
        maxRetries: 3,
      );

      await expectLater(
        () async {
          await apiClient.send(OpenAiApiRequest.json(body: '{"input":"hi"}'));
        },
        throwsA(isA<OpenAiTransportException>()),
      );
      expect(attempts, 1);
    });

    test('maps transport timeout to timeout error code', () async {
      final engine = OpenAiTtsEngine(
        apiClient: const _FailApiClient(
          OpenAiTransportException(statusCode: 408, message: 'timeout'),
        ),
      );

      await expectLater(
        engine
            .synthesize(
              const TtsRequest(requestId: 'o3', text: 'hello'),
              SynthesisControl(),
              _mp3Spec,
            )
            .toList(),
        throwsA(
          isA<TtsError>().having(
            (error) => error.code,
            'code',
            TtsErrorCode.timeout,
          ),
        ),
      );
    });

    test('fromClientConfig maps 401 response to authFailed', () async {
      final client = MockClient(
        (request) async => http.Response('unauthorized', 401),
      );
      final engine = OpenAiTtsEngine.fromClientConfig(
        config: const OpenAiClientConfig(apiKey: ''),
        httpClient: client,
      );

      await expectLater(
        engine
            .synthesize(
              const TtsRequest(requestId: 'o4', text: 'hello'),
              SynthesisControl(),
              _mp3Spec,
            )
            .toList(),
        throwsA(
          isA<TtsError>().having(
            (error) => error.code,
            'code',
            TtsErrorCode.authFailed,
          ),
        ),
      );
    });

    test('engine subclass can parse JSON-envelope response with base64 audio',
        () async {
      final audioBytes = Uint8List.fromList([10, 20, 30, 40, 50]);
      final jsonBody = jsonEncode({'audio': base64Encode(audioBytes)});

      final engine = _JsonEnvelopeEngine(
        apiClient: _SuccessApiClient(
          streamChunks: [utf8.encode(jsonBody)],
        ),
      );

      final chunks = await engine
          .synthesize(
            const TtsRequest(requestId: 'j1', text: 'hello'),
            SynthesisControl(),
            _mp3Spec,
          )
          .toList();

      expect(chunks, hasLength(1));
      expect(chunks.single.bytes, audioBytes);
      expect(chunks.single.isLastChunk, isTrue);
    });
  });
}

final class _SuccessApiClient implements OpenAiApiClient {
  const _SuccessApiClient({this.streamChunks});

  final List<List<int>>? streamChunks;

  @override
  Future<http.StreamedResponse> send(OpenAiApiRequest request) async {
    final chunks = streamChunks ??
        [
          Uint8List.fromList(List<int>.generate(10, (i) => i)),
        ];
    return _streamedResponse(chunks);
  }
}

final class _FailApiClient implements OpenAiApiClient {
  const _FailApiClient(this.error);

  final Exception error;

  @override
  Future<http.StreamedResponse> send(OpenAiApiRequest request) {
    return Future<http.StreamedResponse>.error(error);
  }
}

final class _CallbackApiClient implements OpenAiApiClient {
  const _CallbackApiClient(this.callback);

  final Future<http.StreamedResponse> Function() callback;

  @override
  Future<http.StreamedResponse> send(OpenAiApiRequest request) {
    return callback();
  }
}

http.StreamedResponse _streamedResponse(
  List<List<int>> chunks, {
  int statusCode = 200,
}) {
  return http.StreamedResponse(
    Stream<List<int>>.fromIterable(chunks),
    statusCode,
  );
}

/// Engine subclass that parses {"audio": "\<base64>"} JSON envelopes.
final class _JsonEnvelopeEngine extends OpenAiTtsEngine {
  _JsonEnvelopeEngine({required super.apiClient});

  @override
  Stream<List<int>> parseSuccessResponse(
    http.StreamedResponse response,
    TtsRequest request,
    TtsAudioFormat resolvedFormat,
  ) async* {
    final builder = BytesBuilder(copy: false);
    await for (final chunk in response.stream) {
      builder.add(chunk);
    }
    final body =
        jsonDecode(utf8.decode(builder.takeBytes())) as Map<String, Object?>;
    yield base64Decode(body['audio'] as String);
  }
}
