import 'dart:convert';

import 'package:tts_flow_dart/tts_flow_dart.dart';

/// Builds the SSML body accepted by Azure Speech's REST endpoint.
final class AzureSsmlBuilder {
  const AzureSsmlBuilder({
    required this.defaultVoiceId,
    required this.defaultVoiceLocale,
  });

  final String defaultVoiceId;
  final String defaultVoiceLocale;

  String build(TtsRequest request) {
    final voice = request.voice;
    final voiceId = voice?.voiceId ?? defaultVoiceId;
    final locale = voice?.locale ?? defaultVoiceLocale;
    final speed = request.options?.speed;
    final rate = speed == null ? null : '${(speed * 100).round()}%';
    final content = _escapeXml(request.text);
    final speech = rate == null
        ? content
        : '<prosody rate="$rate">$content</prosody>';
    return '<speak version="1.0" xml:lang="${_escapeXml(locale)}" '
        'xmlns="http://www.w3.org/2001/10/synthesis">'
        '<voice name="${_escapeXml(voiceId)}">$speech</voice>'
        '</speak>';
  }

  String _escapeXml(String input) => input
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;')
      .replaceAll('"', '&quot;')
      .replaceAll("'", '&apos;');
}

/// Parses Azure's voice-list payload while applying the configured default.
final class AzureSpeechVoiceParser {
  const AzureSpeechVoiceParser({required this.defaultVoiceId});

  final String defaultVoiceId;

  List<TtsVoice> parse(String body) {
    final payload = jsonDecode(body);
    if (payload is! List) {
      throw const FormatException(
        'Azure Speech voice-list response must be a JSON array.',
      );
    }
    return payload
        .whereType<Map<String, Object?>>()
        .map(_voiceFromJson)
        .whereType<TtsVoice>()
        .toList(growable: false);
  }

  TtsVoice? _voiceFromJson(Map<String, Object?> value) {
    final voiceId = value['ShortName'];
    if (voiceId is! String || voiceId.isEmpty) {
      return null;
    }
    final displayName = value['DisplayName'];
    final locale = value['Locale'];
    return TtsVoice(
      voiceId: voiceId,
      locale: locale is String ? locale : null,
      displayName: displayName is String ? displayName : voiceId,
      isDefault: voiceId == defaultVoiceId,
    );
  }
}
