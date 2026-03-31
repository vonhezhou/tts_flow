library;

import 'dart:convert';

import 'package:characters/characters.dart';

/// Splits [text] into a list of chunks where each chunk's UTF-8 byte length
/// does not exceed [maxBytes].
///
/// This function is "safe" for TTS (Text-to-Speech) and web processing because:
/// 1. **Protects Entities**: It ensures HTML entities (e.g., `&quot;`, `&#123;`)
///    are treated as single units and never split in the middle.
/// 2. **Grapheme Aware**: It uses the `characters` package to avoid splitting
///    complex characters like emojis or accented letters into invalid byte sequences.
/// 3. **Greedy Allocation**: It packs as many characters as possible into each
///    chunk before starting a new one.
///
/// Returns an empty list if [text] is empty or [maxBytes] is 0 or less.
/// If a single entity or character exceeds [maxBytes], it will be placed
/// in its own standalone chunk.
List<String> ttsSplitText(String text, int maxBytes) {
  if (text.isEmpty || maxBytes <= 0) return [];

  /* ---------- 1. 先把转义实体“保护”起来 ---------- */
  final escapeRegex = RegExp(
    r'&(?:[a-zA-Z][a-zA-Z0-9]*|#(?:x[0-9a-fA-F]+|[0-9]+));',
  );
  final protected = <_Token>[];
  int last = 0;
  for (final m in escapeRegex.allMatches(text)) {
    if (m.start > last) {
      protected.addAll(
        _tokenizeGraphemeClusters(text.substring(last, m.start)),
      );
    }
    protected.add(_Token(m[0]!, true)); // 实体整体
    last = m.end;
  }
  if (last < text.length) {
    protected.addAll(_tokenizeGraphemeClusters(text.substring(last)));
  }

  /* ---------- 2. 贪心装箱 ---------- */
  final chunks = <String>[];
  final sb = StringBuffer();
  int currentBytes = 0;

  for (final token in protected) {
    final tokenBytes = utf8.encode(token.text).length;
    if (currentBytes + tokenBytes > maxBytes) {
      if (sb.isEmpty) {
        // 单个 token 超上限 → 独立成块（或抛异常）
        chunks.add(token.text);
        continue;
      }
      chunks.add(sb.toString());
      sb.clear();
      currentBytes = 0;
      // 重试同一个 token
      if (tokenBytes <= maxBytes) {
        sb.write(token.text);
        currentBytes = tokenBytes;
      } else {
        chunks.add(token.text);
      }
    } else {
      sb.write(token.text);
      currentBytes += tokenBytes;
    }
  }
  if (sb.isNotEmpty) chunks.add(sb.toString());
  return chunks;
}

/* ---------- 3. 把一段普通文本按 grapheme 拆成 token ---------- */
List<_Token> _tokenizeGraphemeClusters(String slice) {
  final out = <_Token>[];
  for (final gc in slice.characters) {
    out.add(_Token(gc, false));
  }
  return out;
}

class _Token {
  final String text;
  final bool isEntity;
  const _Token(this.text, this.isEntity);
}
