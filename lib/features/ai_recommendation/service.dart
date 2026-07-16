import 'dart:convert';

import 'package:PiliPlus/features/ai_recommendation/client.dart';
import 'package:PiliPlus/features/ai_recommendation/model.dart';
import 'package:PiliPlus/features/ai_recommendation/preferences.dart';
import 'package:PiliPlus/features/ai_recommendation/repository.dart';
import 'package:PiliPlus/features/ai_recommendation/secret_store.dart';
import 'package:PiliPlus/http/loading_state.dart';
import 'package:PiliPlus/http/video.dart';
import 'package:PiliPlus/models/model_rec_video_item.dart';
import 'package:PiliPlus/utils/storage_pref.dart';
import 'package:dio/dio.dart';

class AiRecommendationService {
  AiRecommendationService({AiRecommendationClient? client})
    : _client = client ?? AiRecommendationClient();

  final AiRecommendationClient _client;

  Future<AiRecommendationFeed> refresh() async {
    await AiRecommendationRepository.markAttempt();
    try {
      final feed = switch (AiRecommendationPreferences.mode) {
        AiRecommendationMode.local => await _generateLocal(),
        AiRecommendationMode.vps => await _fetchRemote(),
      };
      await AiRecommendationRepository.write(feed);
      return feed;
    } catch (error) {
      await AiRecommendationRepository.writeError(error);
      rethrow;
    }
  }

  Future<AiRecommendationFeed> _generateLocal() async {
    final apiKey = await AiRecommendationSecretStore.readApiKey();
    if (apiKey.isEmpty) {
      throw const AiRecommendationException('请先填写 API Key');
    }
    final model = AiRecommendationPreferences.model.trim();
    if (model.isEmpty) {
      throw const AiRecommendationException('请先填写模型名称');
    }

    final candidates = await _fetchCandidates(
      AiRecommendationPreferences.candidateCount,
    );
    final decisions = await _client.rank(
      apiFormat: AiRecommendationPreferences.apiFormat,
      endpoint: AiRecommendationPreferences.endpoint,
      apiKey: apiKey,
      model: model,
      preference: AiRecommendationPreferences.preference,
      resultCount: AiRecommendationPreferences.resultCount,
      candidates: candidates,
    );

    final byBvid = {
      for (final candidate in candidates) candidate.bvid: candidate,
    };
    final items = decisions
        .where((decision) => byBvid.containsKey(decision.bvid))
        .take(AiRecommendationPreferences.resultCount)
        .map(
          (decision) => AiRecommendationItem.fromDecision(
            byBvid[decision.bvid]!,
            decision,
          ),
        )
        .toList();
    if (items.isEmpty) {
      throw const AiRecommendationException('AI 没有返回有效候选视频');
    }

    return AiRecommendationFeed(
      generatedAt: DateTime.now(),
      source: 'local',
      preferenceSnapshot: AiRecommendationPreferences.preference,
      items: items,
    );
  }

  Future<List<AiRecommendationCandidate>> _fetchCandidates(int target) async {
    final candidates = <AiRecommendationCandidate>[];
    final bvids = <String>{};
    for (var page = 0; page < 8 && candidates.length < target; page++) {
      final LoadingState<List<BaseRcmdVideoItemModel>> state;
      if (Pref.appRcmd) {
        state = await VideoHttp.rcmdVideoListApp(freshIdx: page);
      } else {
        state = await VideoHttp.rcmdVideoList(freshIdx: page, ps: 20);
      }
      switch (state) {
        case Success(:final response):
          for (final video in response) {
            if (video.goto == 'av' &&
                video.bvid?.isNotEmpty == true &&
                bvids.add(video.bvid!)) {
              candidates.add(AiRecommendationCandidate.fromVideo(video));
              if (candidates.length == target) break;
            }
          }
        case Error(:final errMsg):
          if (candidates.isEmpty) {
            throw AiRecommendationException(errMsg ?? '获取 B 站推荐流失败');
          }
        case Loading():
          break;
      }
    }
    if (candidates.isEmpty) {
      throw const AiRecommendationException('B 站推荐流没有返回候选视频');
    }
    return candidates;
  }

  Future<AiRecommendationFeed> _fetchRemote() async {
    final url = AiRecommendationPreferences.remoteUrl.trim();
    final uri = Uri.tryParse(url);
    if (uri == null ||
        !uri.hasScheme ||
        !const {'http', 'https'}.contains(uri.scheme)) {
      throw const AiRecommendationException('VPS JSON 地址无效');
    }
    try {
      final response = await Dio(
        BaseOptions(
          connectTimeout: const Duration(seconds: 15),
          receiveTimeout: const Duration(seconds: 30),
        ),
      ).getUri(uri);
      final Object? data = response.data;
      final map = switch (data) {
        Map data => Map<String, dynamic>.from(data),
        String data => Map<String, dynamic>.from(jsonDecode(data) as Map),
        _ => throw const FormatException('响应不是 JSON 对象'),
      };
      final feed = AiRecommendationFeed.fromJson(map);
      if (feed.items.isEmpty) {
        throw const FormatException('VPS JSON 没有推荐内容');
      }
      return feed;
    } on DioException catch (error) {
      throw AiRecommendationException(error.message ?? '拉取 VPS JSON 失败');
    } on FormatException catch (error) {
      throw AiRecommendationException('VPS JSON 格式错误：${error.message}');
    }
  }
}
