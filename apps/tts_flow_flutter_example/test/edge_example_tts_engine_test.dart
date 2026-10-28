import 'dart:async';
import 'dart:typed_data';

import 'package:dart_edge_tts/dart_edge_tts.dart' as edge;
import 'package:flutter_test/flutter_test.dart';
import 'package:tts_flow_dart/tts_flow_dart.dart';
import 'package:tts_flow_flutter_example/edge_example_tts_engine.dart';

void main() {
  const spec = TtsAudioSpec.mp3();
  const request = TtsRequest(requestKey: 'request-1', text: '固定测试语句');

  test(
    'maps fetched voices and request options while retaining MP3 events',
    () async {
      final client = _FakeEdgeClient(
        () => Stream.fromIterable([
          edge.TtsAudioChunk('request-1', Uint8List.fromList([1, 2])),
          edge.TtsAudioChunk('request-1', Uint8List.fromList([3, 4])),
          const edge.TtsUtteranceCompleted('request-1'),
        ]),
      );
      final engine = EdgeExampleTtsEngine(client: client);
      await engine.init();
      expect((await engine.getDefaultVoice()).voiceId, 'zh-CN-XiaoxiaoNeural');
      expect(
        (await engine.getAvailableVoices(locale: 'en_US')).single.voiceId,
        'en-US-AriaNeural',
      );
      final chunks = await engine
          .synthesize(
            const TtsRequest(
              requestKey: 'request-1',
              text: '固定测试语句',
              options: TtsOptions(speed: 1.2, volume: 0.8, pitch: 1.1),
            ),
            SynthesisControl(),
            spec,
          )
          .cast<TtsAudioChunk>()
          .toList();
      expect(chunks.map((c) => c.bytes.toList()), [
        [1, 2],
        [3, 4],
      ]);
      expect(chunks.map((c) => c.sequenceNumber), [0, 1]);
      expect(chunks.map((c) => c.isLastChunk), [false, true]);
      expect(
        chunks.every((c) => c.requestKey == 'request-1' && c.audioSpec == spec),
        isTrue,
      );
      expect(client.lastUtterance?.text, request.text);
      expect(client.lastOptions?.rate, 1.2);
      expect(client.lastOptions?.volume, 0.8);
      expect(client.lastOptions?.pitch, 1.1);
      await engine.dispose();
      expect(client.closed, isTrue);
    },
  );

  test(
    'rejects unsupported format before starting a provider stream',
    () async {
      final client = _FakeEdgeClient(Stream.empty);
      final engine = EdgeExampleTtsEngine(client: client);
      await engine.init();
      await expectLater(
        engine.synthesize(
          request,
          SynthesisControl(),
          TtsAudioSpec.pcm(const PcmDescriptor.s16Mono24KHz()),
        ),
        emitsError(
          isA<TtsError>().having(
            (e) => e.code,
            'code',
            TtsErrorCode.formatNegotiationFailed,
          ),
        ),
      );
      expect(client.lastUtterance, isNull);
      await engine.dispose();
    },
  );

  for (final audio in [false, true]) {
    test(
      'does not accept ${audio ? 'incomplete' : 'empty'} synthesis',
      () async {
        final client = _FakeEdgeClient(
          () => Stream.fromIterable([
            if (audio)
              edge.TtsAudioChunk('request-1', Uint8List.fromList([1, 2])),
            if (!audio) const edge.TtsUtteranceCompleted('request-1'),
          ]),
        );
        final engine = EdgeExampleTtsEngine(client: client);
        await engine.init();
        await expectLater(
          engine.synthesize(request, SynthesisControl(), spec),
          emitsError(isA<TtsError>()),
        );
        await engine.dispose();
      },
    );
  }

  test(
    'cancellation stops a silent transport without waiting for an audio event',
    () async {
      var canceled = false;
      final transport = StreamController<edge.TtsEvent>(
        onCancel: () => canceled = true,
      );
      final client = _FakeEdgeClient(() => transport.stream);
      final engine = EdgeExampleTtsEngine(client: client);
      await engine.init();
      final control = SynthesisControl();
      final done = engine.synthesize(request, control, spec).toList();
      await Future<void>.delayed(Duration.zero);
      control.cancel(CancelReason.stopCurrent);
      expect(await done.timeout(const Duration(seconds: 1)), isEmpty);
      expect(canceled, isTrue);
      await transport.close();
      await engine.dispose();
    },
  );
}

class _FakeEdgeClient extends edge.EdgeTts {
  _FakeEdgeClient(this.events);
  final Stream<edge.TtsEvent> Function() events;
  edge.TtsUtterance? lastUtterance;
  edge.TtsOptions? lastOptions;
  bool closed = false;

  @override
  Future<List<edge.Voice>> listVoices({bool refresh = false}) async => [
    for (final (name, locale) in [
      ('en-US-AriaNeural', 'en-US'),
      ('zh-CN-XiaoxiaoNeural', 'zh-CN'),
    ])
      edge.Voice(
        name: name,
        shortName: name,
        locale: locale,
        gender: 'Female',
        status: 'GA',
      ),
  ];

  @override
  Stream<edge.TtsEvent> stream(
    edge.TtsUtterance utterance, {
    required edge.Voice voice,
    edge.TtsOptions options = const edge.TtsOptions(),
  }) {
    lastUtterance = utterance;
    lastOptions = options;
    return events();
  }

  @override
  Future<void> close() async => closed = true;
}
