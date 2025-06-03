import 'dart:async';
import 'dart:io';
import 'package:ai_buddy/core/config/type_of_bot.dart';
import 'package:ai_buddy/core/config/type_of_message.dart';
import 'package:ai_buddy/core/logger/logger.dart';
import 'package:ai_buddy/feature/gemini/gemini.dart';
import 'package:ai_buddy/feature/hive/model/chat_bot/chat_bot.dart';
import 'package:ai_buddy/feature/hive/model/chat_message/chat_message.dart';
import 'package:ai_buddy/feature/hive/repository/hive_repository.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

final messageListProvider = StateNotifierProvider<MessageListNotifier, ChatBot>(
  (ref) => MessageListNotifier(),
);

class MessageListNotifier extends StateNotifier<ChatBot> {
  MessageListNotifier()
      : super(ChatBot(messagesList: [], id: '', title: '', typeOfBot: ''));

  final uuid = const Uuid();
  final geminiRepository = GeminiRepository();

  Future<void> updateChatBotWithMessage(ChatMessage message) async {
    final newMessageList = [...state.messagesList, message.toJson()];
    await updateChatBot(
      ChatBot(
        messagesList: newMessageList,
        id: state.id,
        title: state.title.isEmpty ? message.text : state.title,
        typeOfBot: state.typeOfBot,
        attachmentPath: state.attachmentPath,
        embeddings: state.embeddings,
      ),
    );
  }

  Future<void> handleSendPressed({
    required String text,
    String? imageFilePath,
  }) async {
    final messageId = uuid.v4();
    final ChatMessage message = ChatMessage(
      id: messageId,
      text: text,
      createdAt: DateTime.now(),
      typeOfMessage: TypeOfMessage.user,
      chatBotId: state.id,
    );
    await updateChatBotWithMessage(message);
    await getGeminiResponse(prompt: text, imageFilePath: imageFilePath);
  }

  Future<void> getGeminiResponse({
    required String prompt,
    String? imageFilePath,
  }) async {
    // Convert existing chat messages to Gemini-compatible parts
    final List<Parts> chatParts = state.messagesList.map((msg) {
      return Parts(text: msg['text'] as String);
    }).toList();

    // Add either embedding prompt or user prompt
    if (state.typeOfBot == TypeOfBot.pdf) {
      final embeddingPrompt = await geminiRepository.promptForEmbedding(
        userPrompt: prompt,
        embeddings: state.embeddings,
      );
      chatParts.add(Parts(text: embeddingPrompt));
    } else {
      chatParts.add(Parts(text: prompt));
    }

    final content = Content(parts: chatParts);
    final String modelMessageId = uuid.v4();

    // Create a placeholder bot message
    final ChatMessage placeholderMessage = ChatMessage(
      id: modelMessageId,
      text: 'waiting for response...',
      createdAt: DateTime.now(),
      typeOfMessage: TypeOfMessage.bot,
      chatBotId: state.id,
    );

    // Insert the placeholder message into the chat
    await updateChatBotWithMessage(placeholderMessage);

    final StringBuffer fullResponseText = StringBuffer();

    // Start streaming response from Gemini
    Stream<Candidates> responseStream;
    if (imageFilePath != null &&
        state.typeOfBot == TypeOfBot.image &&
        File(imageFilePath).existsSync()) {
      final Uint8List imageBytes = File(imageFilePath).readAsBytesSync();
      responseStream =
          geminiRepository.streamContent(content: content, image: imageBytes);
    } else {
      responseStream = geminiRepository.streamContent(content: content);
    }

    responseStream.listen(
      (response) async {
        final parts = response.content?.parts;
        if (parts != null && parts.isNotEmpty) {
          fullResponseText.write(parts.first.text);

          final int messageIndex = state.messagesList
              .indexWhere((msg) => msg['id'] == modelMessageId);
          if (messageIndex != -1) {
            final updatedMessagesList =
                List<Map<String, dynamic>>.from(state.messagesList);

            updatedMessagesList[messageIndex]['text'] =
                fullResponseText.toString();

            final updatedState = ChatBot(
              id: state.id,
              title: state.title,
              typeOfBot: state.typeOfBot,
              messagesList: updatedMessagesList,
              attachmentPath: state.attachmentPath,
              embeddings: state.embeddings,
            );

            await updateChatBot(updatedState);
          }
        }
      },
      onError: (error) {
        logError('Error in response stream: $error');
      },
    );
  }

  Future<void> updateChatBot(ChatBot newChatBot) async {
    state = newChatBot;
    await HiveRepository().saveChatBot(chatBot: state);
  }
}
