import 'package:flutter/foundation.dart';

import '../../domain/engines.dart';

class ChatMessage {
  const ChatMessage({
    required this.role,
    required this.text,
    this.image,
    this.wav,
  });

  final ChatRole role;
  final String text;
  final Uint8List? image;
  final Uint8List? wav;

  ChatTurn get turn => ChatTurn(role: role, text: text);

  ChatMessage copyWith({String? text}) {
    return ChatMessage(
      role: role,
      text: text ?? this.text,
      image: image,
      wav: wav,
    );
  }
}

/// In-memory conversation. Images and audio stay in this process only.
class ChatSession extends ChangeNotifier {
  final messages = <ChatMessage>[];

  int add(ChatMessage message) {
    messages.add(message);
    notifyListeners();
    return messages.length - 1;
  }

  void replace(int index, ChatMessage message) {
    if (index < 0 || index >= messages.length) return;
    messages[index] = message;
    notifyListeners();
  }

  void removeAt(int index) {
    if (index < 0 || index >= messages.length) return;
    messages.removeAt(index);
    notifyListeners();
  }
}
