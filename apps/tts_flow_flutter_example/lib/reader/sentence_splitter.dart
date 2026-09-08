/// A sentence in book-text coordinates.
///
/// Offsets are Dart UTF-16 code-unit offsets and use the half-open form
/// `[startOffset, endOffset)` so they can be used directly by Flutter text.
final class ReaderSentence {
  const ReaderSentence({required this.startOffset, required this.endOffset});

  final int startOffset;
  final int endOffset;
}

/// Lightweight sentence splitting for the reader demo.
///
/// A production reader may replace this with its book-format-aware tokenizer;
/// the important contract is preserving source offsets rather than the exact
/// punctuation policy.
List<ReaderSentence> splitSentences(String text) {
  final sentences = <ReaderSentence>[];
  final sentenceEnd = RegExp(r'[。！？.!?]+[”’"]*');
  final whitespace = RegExp(r'\s');
  var start = 0;

  for (final match in sentenceEnd.allMatches(text)) {
    final end = match.end;
    if (end > start) {
      sentences.add(ReaderSentence(startOffset: start, endOffset: end));
    }
    start = end;
    while (start < text.length && whitespace.hasMatch(text[start])) {
      start++;
    }
  }
  if (start < text.length) {
    sentences.add(ReaderSentence(startOffset: start, endOffset: text.length));
  }
  return sentences;
}
