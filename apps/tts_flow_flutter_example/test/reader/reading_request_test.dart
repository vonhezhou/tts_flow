import 'package:flutter_test/flutter_test.dart';
import 'package:tts_flow_flutter_example/reader/reading_request.dart';
import 'package:tts_flow_flutter_example/reader/sentence_splitter.dart';

void main() {
  test('splits Chinese sentence boundaries in UTF-16 source offsets', () {
    final sentences = splitSentences('你好。世界！');

    expect(sentences, hasLength(2));
    expect(sentences[0].startOffset, 0);
    expect(sentences[0].endOffset, 3);
    expect(sentences[1].startOffset, 3);
    expect(sentences[1].endOffset, 6);
  });

  test('request planning retains document and request-local offsets', () {
    const text = 'First sentence. Second sentence. Third sentence.';
    final requests = planReadingRequests(
      text: text,
      requestIdPrefix: 'chapter-1',
      maxCharactersPerRequest: 36,
    );

    expect(requests, hasLength(2));
    final first = requests.first;
    expect(first.text, 'First sentence. Second sentence.');
    expect(first.documentStartOffset, 0);
    expect(first.sentences[1].startOffset, text.indexOf('Second'));
    expect(first.sentences[1].endOffset, text.indexOf('Second sentence.') + 16);

    final second = requests.last;
    expect(second.text, 'Third sentence.');
    expect(second.documentStartOffset, text.indexOf('Third'));
    expect(second.sentences.single.startOffset, 0);
  });
}
