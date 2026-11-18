import '../domain/engines.dart';

const chatContextTokens = 2048;
const chatReplyTokenBudget = 512;

String chatSystemPrompt() {
  return 'Reply to the user in the language of their latest message. '
      'Output only the reply.';
}

/// Conservative token estimate. Non-ASCII characters count as one token.
/// ASCII counts as one token per four characters.
int estimateTokens(String text) {
  var tokens = 0;
  var ascii = 0;
  for (final rune in text.runes) {
    if (rune < 128) {
      ascii++;
    } else {
      if (ascii > 0) {
        tokens += (ascii + 3) ~/ 4;
        ascii = 0;
      }
      tokens += 1;
    }
  }
  if (ascii > 0) tokens += (ascii + 3) ~/ 4;
  return tokens;
}

/// Upper bound passed to the text program for one image.
const chatImageTokenReserve = 768;

int chatHistoryTokenBudget() {
  // Leave room for the chat template and special tokens, so the program
  // does not truncate the prompt and echo the cut back into the reply.
  const templateMargin = 256;
  final room =
      chatContextTokens -
      chatReplyTokenBudget -
      estimateTokens(chatSystemPrompt()) -
      templateMargin;
  return room < 64 ? 64 : room;
}

List<ChatTurn> keptChatTurns(List<ChatTurn> turns) {
  final room = chatHistoryTokenBudget();
  final kept = <ChatTurn>[];
  var used = 0;
  for (final turn in turns.reversed) {
    final cost =
        estimateTokens(_line(turn)) +
        1 +
        (turn.image == null ? 0 : chatImageTokenReserve);
    if (kept.isNotEmpty && used + cost > room) break;
    kept.add(turn);
    used += cost;
  }
  return kept.reversed.toList();
}

String chatUserPrompt(List<ChatTurn> turns) {
  return keptChatTurns(turns).map(_line).join('\n');
}

String _line(ChatTurn turn) {
  final speaker = turn.role == ChatRole.assistant ? 'Assistant' : 'User';
  return '$speaker: ${turn.text}';
}
