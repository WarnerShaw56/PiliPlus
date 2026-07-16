import 'package:PiliPlus/features/ai_recommendation/model.dart';
import 'package:PiliPlus/utils/storage.dart';
import 'package:PiliPlus/utils/storage_key.dart';

abstract final class AiRecommendationRepository {
  static AiRecommendationFeed? read() {
    final value = GStorage.localCache.get(LocalCacheKey.aiRecommendationFeed);
    if (value is! Map) return null;
    try {
      return AiRecommendationFeed.fromJson(Map<String, dynamic>.from(value));
    } catch (_) {
      return null;
    }
  }

  static Future<void> write(AiRecommendationFeed feed) async {
    await GStorage.localCache.put(
      LocalCacheKey.aiRecommendationFeed,
      feed.toJson(),
    );
    await GStorage.localCache.delete(LocalCacheKey.aiRecommendationLastError);
  }

  static DateTime? get lastAttempt => DateTime.tryParse(
    GStorage.localCache.get(
      LocalCacheKey.aiRecommendationLastAttempt,
      defaultValue: '',
    ),
  );

  static Future<void> markAttempt() => GStorage.localCache.put(
    LocalCacheKey.aiRecommendationLastAttempt,
    DateTime.now().toUtc().toIso8601String(),
  );

  static String? get lastError =>
      GStorage.localCache.get(LocalCacheKey.aiRecommendationLastError);

  static Future<void> writeError(Object error) => GStorage.localCache.put(
    LocalCacheKey.aiRecommendationLastError,
    error.toString(),
  );
}
