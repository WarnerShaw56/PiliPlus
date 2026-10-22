import 'package:flutter_secure_storage/flutter_secure_storage.dart';

abstract final class AiRecommendationSecretStore {
  static const _apiKeyName = 'ai_recommendation_api_key';
  static const _storage = FlutterSecureStorage();

  static Future<String> readApiKey() async =>
      (await _storage.read(key: _apiKeyName)) ?? '';

  static Future<void> writeApiKey(String value) async {
    final trimmed = value.trim();
    if (trimmed.isEmpty) {
      await _storage.delete(key: _apiKeyName);
    } else {
      await _storage.write(key: _apiKeyName, value: trimmed);
    }
  }
}
