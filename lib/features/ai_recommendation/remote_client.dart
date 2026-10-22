import 'package:PiliPlus/features/ai_recommendation/client.dart';
import 'package:PiliPlus/features/ai_recommendation/model.dart';
import 'package:dio/dio.dart';

class AiRecommendationRemoteClient {
  AiRecommendationRemoteClient({Dio? dio})
    : _dio =
          dio ??
          Dio(
            BaseOptions(
              connectTimeout: const Duration(seconds: 15),
              receiveTimeout: const Duration(seconds: 150),
              sendTimeout: const Duration(seconds: 30),
              contentType: Headers.jsonContentType,
            ),
          );

  final Dio _dio;

  Future<List<AiPreferenceGroup>> listGroups(String feedUrl) async {
    final data = await _request<Map<String, dynamic>>(
      feedUrl,
      'groups',
      method: 'GET',
    );
    return (data['groups'] as List? ?? const [])
        .whereType<Map>()
        .map(
          (group) =>
              AiPreferenceGroup.fromJson(Map<String, dynamic>.from(group)),
        )
        .toList();
  }

  Future<AiPreferenceGroup> expand({
    required String feedUrl,
    required String intent,
    required AiRecommendationSource source,
  }) async {
    final data = await _request<Map<String, dynamic>>(
      feedUrl,
      'groups/expand',
      method: 'POST',
      data: {'intent': intent, 'source': source.name},
    );
    return AiPreferenceGroup.fromJson(data);
  }

  Future<AiPreferenceGroup> create(
    String feedUrl,
    AiPreferenceGroup group,
  ) async {
    final data = await _request<Map<String, dynamic>>(
      feedUrl,
      'groups',
      method: 'POST',
      data: group.toJson(),
    );
    return AiPreferenceGroup.fromJson(data);
  }

  Future<AiPreferenceGroup> update(
    String feedUrl,
    AiPreferenceGroup group,
  ) async {
    final data = await _request<Map<String, dynamic>>(
      feedUrl,
      'groups/${Uri.encodeComponent(group.id)}',
      method: 'PUT',
      data: group.toJson(),
    );
    return AiPreferenceGroup.fromJson(data);
  }

  Future<void> delete(String feedUrl, String groupId) async {
    await _request<Object?>(
      feedUrl,
      'groups/${Uri.encodeComponent(groupId)}',
      method: 'DELETE',
    );
  }

  Future<Map<String, dynamic>> generate(String feedUrl) =>
      _request<Map<String, dynamic>>(feedUrl, 'generate', method: 'POST');

  Future<Map<String, dynamic>> status(String feedUrl) =>
      _request<Map<String, dynamic>>(feedUrl, 'status', method: 'GET');

  Future<T> _request<T>(
    String feedUrl,
    String path, {
    required String method,
    Object? data,
  }) async {
    try {
      final response = await _dio.requestUri<Object?>(
        _apiUri(feedUrl, path),
        data: data,
        options: Options(method: method),
      );
      if (response.data == null) return null as T;
      if (response.data is Map) {
        return Map<String, dynamic>.from(response.data! as Map) as T;
      }
      throw const FormatException('VPS API 响应不是 JSON 对象');
    } on DioException catch (error) {
      final data = error.response?.data;
      final detail = data is Map ? data['detail'] : null;
      throw AiRecommendationException(
        detail?.toString() ?? error.message ?? 'VPS 偏好组请求失败',
      );
    } on FormatException catch (error) {
      throw AiRecommendationException(error.message);
    }
  }

  static Uri _apiUri(String feedUrl, String endpoint) {
    final uri = Uri.tryParse(feedUrl.trim());
    if (uri == null ||
        !uri.hasScheme ||
        !const {'http', 'https'}.contains(uri.scheme)) {
      throw const AiRecommendationException('VPS feed.json 地址无效');
    }
    final segments = [...uri.pathSegments];
    if (segments.isNotEmpty && segments.last == 'feed.json') {
      segments.removeLast();
    }
    if (segments.isEmpty || segments.last != 'api') {
      segments.add('api');
    }
    segments.addAll(endpoint.split('/').where((segment) => segment.isNotEmpty));
    return uri.replace(pathSegments: segments, query: null, fragment: null);
  }
}
