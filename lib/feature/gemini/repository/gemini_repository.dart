// ignore_for_file: inference_failure_on_function_invocation

import 'dart:convert';
import 'dart:math';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:ai_buddy/core/logger/logger.dart';
import 'package:ai_buddy/core/util/secure_storage.dart';
import 'package:ai_buddy/feature/gemini/gemini.dart';
import 'package:ai_buddy/feature/gemini/repository/base_gemini_repository.dart';
import 'package:dio/dio.dart';

class GeminiRepository extends BaseGeminiRepository {
  GeminiRepository();

  final dio = Dio();
  static const baseUrl =
      'https://generativelanguage.googleapis.com/v1beta/models';

  /// Streams content from the Gemini API based on the provided content
  /// and optional image.
  @override
  Stream<Candidates> streamContent({
    required Content content,
    Uint8List? image,
  }) async* {
    try {
      final geminiAPIKey = await SecureStorage().getApiKey();
      logInfo('Retrieved API key: ${geminiAPIKey?.substring(0, 10)}...');

      // Check if API key exists
      if (geminiAPIKey == null || geminiAPIKey.isEmpty) {
        throw Exception(
            'API key is not set. Please configure your Gemini API key.');
      }

      // Use appropriate models for different content types
      final model = image == null ? 'gemini-1.5-flash' : 'gemini-1.5-pro';

      final Map<String, dynamic> requestBody;

      if (image == null) {
        // Text-only request - ensure no duplicate parts
        final textParts = content.parts
                ?.where((part) => part.text?.isNotEmpty == true)
                .map((part) => {'text': part.text})
                .toList() ??
            [];

        requestBody = {
          'contents': [
            {'parts': textParts},
          ],
          'safetySettings': [
            {
              'category': 'HARM_CATEGORY_DANGEROUS_CONTENT',
              'threshold': 'BLOCK_ONLY_HIGH',
            },
          ],
          'generationConfig': {
            'temperature': 0.7,
            'topP': 0.8,
            'topK': 40,
            'maxOutputTokens': 2048,
          },
        };
      } else {
        // Vision request
        final text = content.parts
                ?.lastWhere(
                  (part) => part.text?.isNotEmpty == true,
                  orElse: () => Parts(text: ''),
                )
                .text ??
            '';

        requestBody = {
          'contents': [
            {
              'parts': [
                {'text': text},
                {
                  'inline_data': {
                    'mime_type': 'image/jpeg',
                    'data': base64Encode(image),
                  },
                },
              ],
            }
          ],
          'safetySettings': [
            {
              'category': 'HARM_CATEGORY_DANGEROUS_CONTENT',
              'threshold': 'BLOCK_ONLY_HIGH',
            },
          ],
          'generationConfig': {
            'temperature': 0.7,
            'topP': 0.8,
            'topK': 40,
            'maxOutputTokens': 2048,
          },
        };
      }

      final url = '$baseUrl/$model:streamGenerateContent';

      // Logging for debugging
      logInfo('=== REQUEST DEBUG INFO ===');
      logInfo('Full URL: $url');
      logInfo('Model: $model');
      logInfo('Request body: ${jsonEncode(requestBody)}');

      // Configure Dio with timeout and better error handling
      final dioOptions = BaseOptions(
        connectTimeout: const Duration(seconds: 30),
        receiveTimeout: const Duration(seconds: 60),
        sendTimeout: const Duration(seconds: 30),
      );
      final dioClient = Dio(dioOptions);

      // Add interceptor for logging
      dioClient.interceptors.add(LogInterceptor(
        requestBody: false, // Set to false to avoid large logs
        responseBody: false,
        requestHeader: true,
        responseHeader: false,
        logPrint: (obj) => logInfo('DIO: $obj'),
      ));

      final response = await dioClient.post(
        url,
        options: Options(
          headers: {
            'Content-Type': 'application/json',
            'x-goog-api-key': geminiAPIKey,
          },
          responseType: ResponseType.stream,
          validateStatus: (status) {
            logInfo('Response status received: $status');
            return status != null && status >= 200 && status < 300;
          },
        ),
        data: jsonEncode(requestBody),
      );

      if (response.statusCode == 200) {
        yield* _processStreamResponse(response.data as ResponseBody);
      } else {
        final errorMessage = await _extractErrorMessage(response);
        logError('HTTP ${response.statusCode}: $errorMessage');
        throw Exception(
            'API request failed with status ${response.statusCode}: $errorMessage');
      }
    } catch (e) {
      logError('Error in streamContent: $e');
      rethrow;
    }
  }

  /// Process the streaming response from Gemini API
  Stream<Candidates> _processStreamResponse(ResponseBody responseBody) async* {
    StringBuffer buffer = StringBuffer();
    List<int> byteBuffer = [];

    await for (final chunk in responseBody.stream) {
      byteBuffer.addAll(chunk);

      try {
        final String text = utf8.decode(byteBuffer);
        byteBuffer.clear();
        buffer.write(text);

        // Process complete JSON objects
        String bufferContent = buffer.toString();
        while (bufferContent.isNotEmpty) {
          final processedContent = _processJsonChunk(bufferContent);
          if (processedContent.candidate != null) {
            yield processedContent.candidate!;
          }

          if (processedContent.remainingContent == bufferContent) {
            // No progress made, wait for more data
            break;
          }

          bufferContent = processedContent.remainingContent;
          buffer.clear();
          buffer.write(bufferContent);
        }
      } catch (e) {
        // If UTF-8 decode fails, continue accumulating bytes
        continue;
      }
    }
  }

  /// Process JSON chunks and extract candidates
  ({Candidates? candidate, String remainingContent}) _processJsonChunk(
      String content) {
    try {
      // Clean up the content
      String cleanContent = content.trim();

      // Remove array brackets and leading commas
      if (cleanContent.startsWith('[')) {
        cleanContent = cleanContent.substring(1);
      }
      if (cleanContent.startsWith(',')) {
        cleanContent = cleanContent.substring(1);
      }
      if (cleanContent.endsWith(']')) {
        cleanContent = cleanContent.substring(0, cleanContent.length - 1);
      }

      cleanContent = cleanContent.trim();

      // Try to find complete JSON objects
      int braceCount = 0;
      int startIndex = -1;

      for (int i = 0; i < cleanContent.length; i++) {
        final char = cleanContent[i];
        if (char == '{') {
          if (startIndex == -1) startIndex = i;
          braceCount++;
        } else if (char == '}') {
          braceCount--;
          if (braceCount == 0 && startIndex != -1) {
            // Found complete JSON object
            final jsonStr = cleanContent.substring(startIndex, i + 1);
            try {
              final jsonResponse = jsonDecode(jsonStr);
              if (jsonResponse['candidates'] != null &&
                  (jsonResponse['candidates'] as List).isNotEmpty) {
                final candidate = Candidates.fromJson(
                  (jsonResponse['candidates'] as List).first
                      as Map<String, dynamic>,
                );
                final remaining = cleanContent.substring(i + 1);
                return (candidate: candidate, remainingContent: remaining);
              }
            } catch (e) {
              // Invalid JSON, continue searching
            }
            startIndex = -1;
          }
        }
      }

      return (candidate: null, remainingContent: cleanContent);
    } catch (e) {
      logError('Error processing JSON chunk: $e');
      return (candidate: null, remainingContent: content);
    }
  }

  /// Extract error message from response
  Future<String> _extractErrorMessage(Response response) async {
    try {
      if (response.data is ResponseBody) {
        final responseBody = response.data as ResponseBody;
        final bytes = await responseBody.stream.toList();
        final allBytes = bytes.expand((x) => x).toList();
        return utf8.decode(allBytes);
      }
      return response.data?.toString() ?? 'Unknown error';
    } catch (e) {
      return 'Failed to extract error message: $e';
    }
  }

  @override
  Future<Map<String, List<num>>> batchEmbedChunks({
    required List<String> textChunks,
  }) async {
    try {
      final geminiAPIKey = await SecureStorage().getApiKey();

      if (geminiAPIKey == null || geminiAPIKey.isEmpty) {
        throw Exception(
            'API key is not set. Please configure your Gemini API key.');
      }

      final Map<String, List<num>> embeddingsMap = {};
      const int batchSize = 100; // Adjust based on API limits

      for (int i = 0; i < textChunks.length; i += batchSize) {
        final end = math.min(i + batchSize, textChunks.length);
        final batch = textChunks.sublist(i, end);

        final response = await dio.post(
          '$baseUrl/text-embedding-004:batchEmbedContents',
          options: Options(
            headers: {
              'Content-Type': 'application/json',
              'x-goog-api-key': geminiAPIKey,
            },
          ),
          data: {
            'requests': batch
                .map((text) => {
                      'model': 'models/text-embedding-004',
                      'content': {
                        'parts': [
                          {'text': text}
                        ],
                      },
                      'taskType': 'RETRIEVAL_DOCUMENT',
                    })
                .toList(),
          },
        );

        if (response.statusCode == 200) {
          final embeddings = response.data['embeddings'] as List;
          for (int j = 0; j < batch.length; j++) {
            if (j < embeddings.length && embeddings[j]['values'] != null) {
              embeddingsMap[batch[j]] =
                  (embeddings[j]['values'] as List).cast<num>();
            }
          }
        } else {
          logError('Batch embed failed: ${response.statusCode}');
          throw Exception('Failed to embed batch: ${response.statusCode}');
        }
      }

      return embeddingsMap;
    } catch (e) {
      logError('Error in batchEmbedChunks: $e');
      rethrow;
    }
  }

  @override
  Future<String> promptForEmbedding({
    required String userPrompt,
    required Map<String, List<num>>? embeddings,
  }) async {
    try {
      final geminiAPIKey = await SecureStorage().getApiKey();

      if (geminiAPIKey == null || geminiAPIKey.isEmpty) {
        throw Exception(
            'API key is not set. Please configure your Gemini API key.');
      }

      final response = await dio.post(
        '$baseUrl/text-embedding-004:embedContent',
        options: Options(
          headers: {
            'Content-Type': 'application/json',
            'x-goog-api-key': geminiAPIKey,
          },
        ),
        data: {
          'model': 'models/text-embedding-004',
          'content': {
            'parts': [
              {'text': userPrompt}
            ],
          },
          'taskType': 'RETRIEVAL_QUERY',
        },
      );

      if (response.statusCode != 200) {
        throw Exception('Failed to get embedding: ${response.statusCode}');
      }

      final currentEmbedding =
          (response.data['embedding']['values'] as List).cast<num>();

      if (embeddings == null || embeddings.isEmpty) {
        return 'Error: No embeddings available for comparison.';
      }

      // Calculate similarities (using cosine similarity instead of Euclidean distance)
      final Map<String, double> similarities = {};
      embeddings.forEach((text, embedding) {
        final similarity =
            _calculateCosineSimilarity(currentEmbedding, embedding);
        similarities[text] = similarity;
      });

      // Sort by highest similarity (descending order)
      final sortedSimilarities = similarities.entries.toList()
        ..sort((a, b) => b.value.compareTo(a.value));

      // Get top 4 most similar chunks
      final topChunks =
          sortedSimilarities.take(4).map((entry) => entry.key).join('\n\n');

      final prompt = '''
You're a chat with PDF AI assistant.

I'm providing you with the most relevant text from the PDF attached by the user. Your job is to read the following text delimited by #### carefully and answer the user's prompt.

####
$topChunks
####

User's question: $userPrompt

Instructions:
- Give a friendly, crisp, and precise answer
- Use simple and easy-to-understand language
- Avoid buzzwords and jargon
- If the question is unrelated to the PDF content, respond with your general knowledge
- If you don't know the answer, simply say "I don't know" or "I'm not sure"
''';

      return prompt;
    } catch (e) {
      logError('Error in prompt generation: $e');
      return 'An error occurred while processing your request. Please try again.';
    }
  }

  /// Calculate cosine similarity between two vectors
  double _calculateCosineSimilarity(List<num> vectorA, List<num> vectorB) {
    if (vectorA.length != vectorB.length) {
      throw ArgumentError('Vectors must have the same length');
    }

    double dotProduct = 0.0;
    double normA = 0.0;
    double normB = 0.0;

    for (int i = 0; i < vectorA.length; i++) {
      final a = vectorA[i].toDouble();
      final b = vectorB[i].toDouble();

      dotProduct += a * b;
      normA += a * a;
      normB += b * b;
    }

    if (normA == 0.0 || normB == 0.0) {
      return 0.0;
    }

    return dotProduct / (sqrt(normA) * sqrt(normB));
  }

  @override
  double calculateEuclideanDistance({
    required List<num> vectorA,
    required List<num> vectorB,
  }) {
    if (vectorA.length != vectorB.length) {
      throw ArgumentError('Vectors must have the same length');
    }

    double sum = 0.0;
    for (int i = 0; i < vectorA.length; i++) {
      final diff = vectorA[i].toDouble() - vectorB[i].toDouble();
      sum += diff * diff;
    }

    return sqrt(sum);
  }
}
