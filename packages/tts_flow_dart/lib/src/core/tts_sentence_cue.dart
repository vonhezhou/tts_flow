/// A sentence range aligned to a point on a request's rendered audio timeline.
///
/// Text offsets are UTF-16 code-unit offsets into the exact
/// [TtsRequest.text] passed to synthesis and form a half-open range:
/// `[startOffset, endOffset)`. [audioStart] is relative to the beginning of
/// that request's audio, not to its network arrival time.
final class TtsSentenceCue {
  const TtsSentenceCue({
    required this.startOffset,
    required this.endOffset,
    required this.audioStart,
  }) : assert(startOffset >= 0),
       assert(endOffset > startOffset);

  final int startOffset;
  final int endOffset;
  final Duration audioStart;
}
