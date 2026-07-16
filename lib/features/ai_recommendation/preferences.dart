import 'package:PiliPlus/features/ai_recommendation/model.dart';
import 'package:PiliPlus/utils/storage.dart';
import 'package:PiliPlus/utils/storage_key.dart';

abstract final class AiRecommendationPreferences {
  static const defaultPreference =
      '优先推荐信息密度高、论证扎实、有新知识或独到观点的视频；'
      '降低标题党、重复搬运、纯情绪输出和低信息密度内容的分数。';

  static bool get enabled =>
      GStorage.setting.get(SettingBoxKey.aiRcmdEnabled, defaultValue: false);

  static AiRecommendationMode get mode {
    final value = GStorage.setting.get(
      SettingBoxKey.aiRcmdMode,
      defaultValue: AiRecommendationMode.local.name,
    );
    return AiRecommendationMode.values.firstWhere(
      (mode) => mode.name == value,
      orElse: () => AiRecommendationMode.local,
    );
  }

  static String get endpoint => GStorage.setting.get(
    SettingBoxKey.aiRcmdEndpoint,
    defaultValue: 'https://api.openai.com/v1',
  );

  static AiApiFormat get apiFormat {
    final value = GStorage.setting.get(
      SettingBoxKey.aiRcmdApiFormat,
      defaultValue: AiApiFormat.openAi.name,
    );
    return AiApiFormat.values.firstWhere(
      (format) => format.name == value,
      orElse: () => AiApiFormat.openAi,
    );
  }

  static String get model =>
      GStorage.setting.get(SettingBoxKey.aiRcmdModel, defaultValue: '');

  static String get preference => GStorage.setting.get(
    SettingBoxKey.aiRcmdPreference,
    defaultValue: defaultPreference,
  );

  static int get dailyHour =>
      GStorage.setting.get(SettingBoxKey.aiRcmdDailyHour, defaultValue: 8);

  static int get candidateCount => GStorage.setting.get(
    SettingBoxKey.aiRcmdCandidateCount,
    defaultValue: 30,
  );

  static int get resultCount =>
      GStorage.setting.get(SettingBoxKey.aiRcmdResultCount, defaultValue: 8);

  static String get remoteUrl =>
      GStorage.setting.get(SettingBoxKey.aiRcmdRemoteUrl, defaultValue: '');
}
