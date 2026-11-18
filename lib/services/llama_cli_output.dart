String parseLlamaCliOutput(
  String raw,
  String prompt, {
  bool finished = false,
}) {
  final cleaned = raw
      .replaceAll('\b', '')
      .replaceAll(RegExp(r'\x1b\[[0-9;]*[A-Za-z]'), '');
  // A line is visible once it ends, or once the program has exited.
  // Otherwise the first letters of "model" are shown as the translation.
  final complete =
      finished || cleaned.endsWith('\n') || cleaned.endsWith('\r');
  var source = cleaned;
  if (!complete) {
    final cut = source.lastIndexOf('\n');
    if (cut < 0) return '';
    source = source.substring(0, cut + 1);
  }
  final lines = source.split(RegExp(r'\r?\n'));
  final promptLines = prompt.trim().split(RegExp(r'\r?\n'));
  final fromChat = _afterEcho(lines, promptLines);
  if (fromChat.isNotEmpty) return fromChat;

  final plain = <String>[];
  for (final line in lines) {
    final trimmed = line.trim();
    if (trimmed.isEmpty ||
        _isLog(trimmed) ||
        _isPromptEcho(trimmed, promptLines)) {
      continue;
    }
    plain.add(trimmed);
  }
  return _cleanModelText(plain.join('\n'), promptLines);
}

String _afterEcho(List<String> lines, List<String> promptLines) {
  if (promptLines.isEmpty || promptLines.first.isEmpty) return '';
  var index = 0;
  var started = false;
  final answer = <String>[];
  for (final line in lines) {
    final trimmed = line.trim();
    if (!started) {
      if (index < promptLines.length &&
          (trimmed == promptLines[index] ||
              trimmed == '> ${promptLines[index]}')) {
        index++;
        if (index == promptLines.length) started = true;
      }
      continue;
    }
    if (trimmed.isEmpty) {
      if (answer.isNotEmpty) answer.add('');
      continue;
    }
    if (_isBoundary(trimmed)) break;
    answer.add(trimmed);
  }
  if (!started) return '';
  return _cleanModelText(answer.join('\n'), promptLines);
}

bool _isPromptEcho(String trimmed, List<String> promptLines) {
  for (final line in promptLines) {
    if (trimmed == line || trimmed == '> $line') return true;
  }
  return false;
}

bool _isBoundary(String trimmed) {
  return trimmed == '>' ||
      trimmed.startsWith('> ') ||
      trimmed.startsWith('[ Prompt:') ||
      trimmed == 'Exiting...' ||
      trimmed.startsWith('Exiting');
}

String _cleanModelText(String text, List<String> promptLines) {
  final kept = <String>[];
  var dropWrappedPattern = false;
  var pendingBlank = false;
  for (final line in text.split(RegExp(r'\r?\n'))) {
    final trimmed = _stripTruncationMarkers(line.trim());
    if (trimmed.isEmpty) {
      if (kept.isNotEmpty) pendingBlank = true;
      continue;
    }
    if (_isCliChrome(trimmed)) {
      dropWrappedPattern =
          trimmed.startsWith('/glob') || trimmed.contains('globbing');
      continue;
    }
    if (dropWrappedPattern && trimmed == 'pattern') {
      dropWrappedPattern = false;
      continue;
    }
    dropWrappedPattern = false;
    if (_isTruncatedContentEcho(trimmed, promptLines)) continue;
    final echoed = _withoutCliEcho(_stripArtifacts(trimmed), promptLines);
    if (echoed == null || echoed.isEmpty) continue;
    final cleaned = _withoutRoleEcho(echoed, promptLines);
    if (cleaned == null || cleaned.isEmpty) continue;
    if (pendingBlank) kept.add('');
    pendingBlank = false;
    kept.add(cleaned);
  }
  return kept.join('\n').trim();
}

/// Drops `> ` plus the part of the source glued to the translation.
String? _withoutCliEcho(String line, List<String> promptLines) {
  final mark = line.indexOf('>');
  if (mark < 0) return line;
  final body = line.substring(mark + 1).trimLeft();
  if (body.isEmpty) return null;
  String? rest;
  var matched = 0;
  for (final promptLine in promptLines) {
    final prompt = promptLine.trim();
    if (prompt.isEmpty) continue;
    if (body.startsWith(prompt)) {
      final common = prompt.runes.length;
      if (common < matched) continue;
      matched = common;
      rest = body.substring(prompt.length).trimLeft();
      continue;
    }
    final common = _commonPrefixRunes(body.runes.toList(), prompt.runes.toList());
    if (common < 4 || common <= matched) continue;
    final shared = String.fromCharCodes(body.runes.take(common));
    if (!_isStrictPrefix(prompt, shared)) continue;
    matched = common;
    rest = String.fromCharCodes(body.runes.skip(common)).trimLeft();
  }
  if (rest == null) return line;
  return rest.isEmpty ? null : rest;
}

/// A cut prompt line comes back with `...` on the end, such as `- 八 (b ...`.
bool _isTruncatedContentEcho(String line, List<String> promptLines) {
  if (!line.endsWith('...')) return false;
  final prefix = line.substring(0, line.length - 3).trimRight();
  if (prefix.isEmpty) return false;
  for (final promptLine in promptLines) {
    if (_isStrictPrefix(promptLine, prefix)) return true;
    for (final role in const ['User: ', 'Assistant: ']) {
      if (!promptLine.startsWith(role)) continue;
      if (_isStrictPrefix(promptLine.substring(role.length), prefix)) {
        return true;
      }
    }
  }
  return false;
}

bool _isStrictPrefix(String text, String prefix) {
  return text.startsWith(prefix) && text.length > prefix.length;
}

/// Drops a truncated copy of a prompt line. A reply glued onto that copy stays.
String? _withoutRoleEcho(String line, List<String> promptLines) {
  final match = RegExp(r'^(User|Assistant): (.*)$').firstMatch(line);
  if (match == null) return line;
  final role = match.group(1)!;
  var body = match.group(2)!;
  for (final promptLine in promptLines) {
    if (!promptLine.startsWith('$role: ')) continue;
    final promptBody = promptLine.substring(role.length + 2);
    if (promptBody.isEmpty || body.isEmpty) continue;
    if (body.startsWith(promptBody)) {
      body = body.substring(promptBody.length).trimLeft();
      break;
    }
    final bodyRunes = body.runes.toList();
    final promptRunes = promptBody.runes.toList();
    if (_startsWithRunes(promptRunes, bodyRunes) && bodyRunes.length >= 8) {
      return null;
    }
    final common = _commonPrefixRunes(bodyRunes, promptRunes);
    if (common >= 8 &&
        common < bodyRunes.length &&
        common < promptRunes.length) {
      body = String.fromCharCodes(bodyRunes.skip(common)).trimLeft();
      break;
    }
  }
  return body.trim();
}

bool _startsWithRunes(List<int> text, List<int> prefix) {
  if (prefix.length > text.length) return false;
  for (var i = 0; i < prefix.length; i++) {
    if (text[i] != prefix[i]) return false;
  }
  return true;
}

int _commonPrefixRunes(List<int> a, List<int> b) {
  final n = a.length < b.length ? a.length : b.length;
  var i = 0;
  while (i < n && a[i] == b[i]) {
    i++;
  }
  return i;
}

String _stripTruncationMarkers(String text) {
  return text
      .replaceAll('(truncated)', '')
      .replaceAll('User: ...', '')
      .replaceAll(RegExp(r'[ \t]{2,}'), ' ')
      .trim();
}

bool _isCliChrome(String trimmed) {
  if (RegExp(
    r'^/(help|exit|regen|clear|read|glob|image)\b',
  ).hasMatch(trimmed)) {
    return true;
  }
  switch (trimmed) {
    case 'regenerate the last response':
    case 'clear the chat history':
    case 'add a text file':
    case 'add text files using globbing':
    case 'add text files using globbing pattern':
    case 'add an image file':
    case '(truncated)':
    case 'truncated':
      return true;
  }
  return false;
}

String _stripArtifacts(String text) {
  final buffer = StringBuffer();
  for (final rune in text.runes) {
    if (_isArtifactRune(rune)) continue;
    buffer.writeCharCode(rune);
  }
  return buffer
      .toString()
      .replaceAll(RegExp(r'<\|[^|>\n]{1,80}\|>'), '')
      .replaceAll(RegExp(r'</?think>'), '')
      .replaceAll(RegExp(r'[ \t]{2,}'), ' ')
      .trim();
}

bool _isArtifactRune(int rune) {
  if (rune == 0x09 || rune == 0x0A || rune == 0x0D) return false;
  if (rune < 0x20 || (rune >= 0x7F && rune <= 0x9F)) return true;
  if (rune == 0xFFFC || rune == 0xFFFD) return true;
  if (rune >= 0xE000 && rune <= 0xF8FF) return true;
  if (rune >= 0xF0000 && rune <= 0xFFFFD) return true;
  if (rune >= 0x100000 && rune <= 0x10FFFD) return true;
  if (rune >= 0xFDD0 && rune <= 0xFDEF) return true;
  if ((rune & 0xFFFE) == 0xFFFE) return true;
  if (rune >= 0x25A0 && rune <= 0x25FF) return true;
  if (rune >= 0x2580 && rune <= 0x259F) return true;
  return false;
}

bool _isLog(String trimmed) {
  return trimmed.startsWith('build ') ||
      trimmed.startsWith('model ') ||
      trimmed.startsWith('model:') ||
      trimmed.startsWith('Loading') ||
      trimmed.startsWith('Loaded media') ||
      trimmed.startsWith('Exiting') ||
      trimmed.startsWith('[ Prompt:') ||
      trimmed.startsWith('available commands') ||
      trimmed.startsWith('llama_') ||
      trimmed.startsWith('ggml_') ||
      trimmed.startsWith('/exit') ||
      trimmed.startsWith('using custom') ||
      trimmed.startsWith('modalities') ||
      trimmed.startsWith('ftype') ||
      trimmed.contains('▄') ||
      trimmed.contains('██');
}
