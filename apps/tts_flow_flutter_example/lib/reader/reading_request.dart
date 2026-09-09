import 'package:tts_flow_flutter_example/reader/sentence_splitter.dart';

/// A group of book sentences synthesized as one TTS request.
final class ReadingRequest {
  const ReadingRequest({
    required this.utteranceId,
    required this.text,
    required this.documentStartOffset,
    required this.sentences,
  });

  /// Business correlation label for this planned portion of text.
  final String utteranceId;
  final String text;
  final int documentStartOffset;
  final List<ReaderSentence> sentences;
}

/// Creates modest request-sized groups while preserving book-text offsets.
List<ReadingRequest> planReadingRequests({
  required String text,
  required String utteranceIdPrefix,
  int maxCharactersPerRequest = 160,
}) {
  if (maxCharactersPerRequest <= 0) {
    throw ArgumentError.value(
      maxCharactersPerRequest,
      'maxCharactersPerRequest',
      'Must be greater than zero.',
    );
  }

  final sourceSentences = splitSentences(text);
  final requests = <ReadingRequest>[];
  var groupStart = 0;
  var groupEnd = 0;
  var group = <ReaderSentence>[];

  void commitGroup() {
    if (group.isEmpty) {
      return;
    }
    final requestIndex = requests.length;
    final requestText = text.substring(groupStart, groupEnd);
    final localSentences = group
        .map(
          (sentence) => ReaderSentence(
            startOffset: sentence.startOffset - groupStart,
            endOffset: sentence.endOffset - groupStart,
          ),
        )
        .toList(growable: false);
    requests.add(
      ReadingRequest(
        utteranceId: '$utteranceIdPrefix-$requestIndex',
        text: requestText,
        documentStartOffset: groupStart,
        sentences: localSentences,
      ),
    );
    group = <ReaderSentence>[];
  }

  for (final sentence in sourceSentences) {
    if (group.isEmpty) {
      groupStart = sentence.startOffset;
      groupEnd = sentence.endOffset;
      group.add(sentence);
      continue;
    }

    if (sentence.endOffset - groupStart > maxCharactersPerRequest) {
      commitGroup();
      groupStart = sentence.startOffset;
      groupEnd = sentence.endOffset;
    } else {
      groupEnd = sentence.endOffset;
    }
    group.add(sentence);
  }
  commitGroup();
  return requests;
}
