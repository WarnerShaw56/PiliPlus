import 'dart:convert';

import 'package:PiliPlus/features/ai_recommendation/model.dart';
import 'package:dio/dio.dart';

class AiRecommendationClient {
  AiRecommendationClient({Dio? dio})
    : _dio =
          dio ??
          Dio(
            BaseOptions(
              connectTimeout: const Duration(seconds: 15),
              receiveTimeout: const Duration(seconds: 90),
              sendTimeout: const Duration(seconds: 30),
              contentType: Headers.jsonContentType,
            ),
          );

  final Dio _dio;

  Future<List<AiRecommendationDecision>> rank({
    required AiApiFormat apiFormat,
    required String endpoint,
    required String apiKey,
    required String model,
    required String preference,
    required int resultCount,
    required List<AiRecommendationCandidate> candidates,
  }) async {
    if (candidates.isEmpty) {
      throw const AiRecommendationException('没有可供 AI 评分的候选视频');
    }

    final uri = _messagesUri(endpoint, apiFormat);
    final systemPrompt =
        '你是严谨的视频内容编辑。只能根据给定候选做相对排序，'
        '不得编造已经看过视频或字幕。输出必须是一个 JSON 对象，不能带 Markdown。';
    final userPrompt = jsonEncode({
      'task':
          '结合用户偏好，从候选中选出最多 $resultCount 条。'
          'score 为 0-100 的时间价值分；reason 用一句中文说明为什么适合用户；'
          'summary 只能概括标题和已有元数据透露的信息，不能虚构内容；'
          'tags 最多 4 个。',
      'user_preference': preference,
      'output_schema': {
        'recommendations': [
          {
            'bvid': '候选中的 bvid',
            'score': 0,
            'reason': 'string',
            'summary': 'string',
            'tags': ['string'],
          },
        ],
      },
      'candidates': candidates
          .map((candidate) => candidate.toPromptJson())
          .toList(),
    });
    try {
      final response = switch (apiFormat) {
        AiApiFormat.openAi => await _dio.postUri<Map<String, dynamic>>(
          uri,
          options: Options(headers: {'authorization': 'Bearer $apiKey'}),
          data: {
            'model': model,
            'temperature': 0.2,
            'messages': [
              {'role': 'system', 'content': systemPrompt},
              {'role': 'user', 'content': userPrompt},
            ],
          },
        ),
        AiApiFormat.anthropic => await _dio.postUri<Map<String, dynamic>>(
          uri,
          options: Options(
            headers: {'x-api-key': apiKey, 'anthropic-version': '2023-06-01'},
          ),
          data: {
            'model': model,
            'max_tokens': 2048,
            'temperature': 0.2,
            'system': systemPrompt,
            'messages': [
              {'role': 'user', 'content': userPrompt},
            ],
          },
        ),
      };

      final content = switch (apiFormat) {
        AiApiFormat.openAi => _extractOpenAiContent(response.data),
        AiApiFormat.anthropic => _extractAnthropicContent(response.data),
      };
      return parseResponseContent(content);
    } on DioException catch (error) {
      final data = error.response?.data;
      final message = data is Map
          ? (data['error'] is Map
                ? (data['error'] as Map)['message']
                : data['message'])
          : null;
      throw AiRecommendationException(
        message?.toString() ?? error.message ?? 'AI 请求失败',
      );
    }
  }

  static List<AiRecommendationDecision> parseResponseContent(String content) {
    final trimmed = content.trim();
    final start = trimmed.indexOf('{');
    final end = trimmed.lastIndexOf('}');
    if (start < 0 || end <= start) {
      throw const AiRecommendationException('AI 没有返回可解析的 JSON');
    }

    try {
      final root = jsonDecode(trimmed.substring(start, end + 1));
      final list = root is Map ? root['recommendations'] : null;
      if (list is! List) {
        throw const FormatException('recommendations 不存在');
      }
      final seen = <String>{};
      final decisions = <AiRecommendationDecision>[];
      for (final value in list) {
        if (value is! Map) continue;
        final decision = AiRecommendationDecision.fromJson(
          Map<String, dynamic>.from(value),
        );
        if (decision.bvid.isNotEmpty && seen.add(decision.bvid)) {
          decisions.add(decision);
        }
      }
      return decisions..sort((a, b) => b.score.compareTo(a.score));
    } catch (error) {
      if (error is AiRecommendationException) rethrow;
      throw AiRecommendationException('AI JSON 格式错误：$error');
    }
  }

  static Uri _messagesUri(String endpoint, AiApiFormat apiFormat) {
    final value = endpoint.trim().replaceFirst(RegExp(r'/+$'), '');
    final path = switch (apiFormat) {
      AiApiFormat.openAi =>
        value.endsWith('/chat/completions') ? value : '$value/chat/completions',
      AiApiFormat.anthropic =>
        value.endsWith('/messages')
            ? value
            : value.endsWith('/v1')
            ? '$value/messages'
            : '$value/v1/messages',
    };
    final uri = Uri.tryParse(path);
    if (uri == null ||
        !uri.hasScheme ||
        !const {'http', 'https'}.contains(uri.scheme)) {
      throw const AiRecommendationException('AI 接口地址无效');
    }
    return uri;
  }

  static String _extractOpenAiContent(Map<String, dynamic>? data) {
    final choices = data?['choices'];
    if (choices is! List || choices.isEmpty) {
      throw const AiRecommendationException('AI 响应缺少 choices');
    }
    final message = (choices.first as Map?)?['message'];
    final content = (message as Map?)?['content'];
    if (content is String) return content;
    if (content is List) {
      return content
          .whereType<Map>()
          .map((part) => part['text'])
          .whereType<String>()
          .join();
    }
    throw const AiRecommendationException('AI 响应缺少文本内容');
  }

  static String _extractAnthropicContent(Map<String, dynamic>? data) {
    final content = data?['content'];
    if (content is List) {
      final text = content
          .whereType<Map>()
          .where((part) => part['type'] == 'text')
          .map((part) => part['text'])
          .whereType<String>()
          .join();
      if (text.isNotEmpty) return text;
    }
    throw const AiRecommendationException('AI 响应缺少文本内容');
  }
}

class AiRecommendationException implements Exception {
  const AiRecommendationException(this.message);

  final String message;

  @override
  String toString() => message;
}
