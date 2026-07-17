import 'package:PiliPlus/models/model_rec_video_item.dart';

enum AiRecommendationMode { local, vps }

enum AiApiFormat { openAi, anthropic }

enum AiRecommendationSource { recommendation, search, hybrid }

class AiPreferenceGroup {
  const AiPreferenceGroup({
    required this.id,
    required this.name,
    required this.intent,
    required this.prompt,
    required this.source,
    this.searchQueries = const [],
    this.resultCount = 8,
    this.minimumDurationSeconds = 900,
    this.enabled = true,
  });

  factory AiPreferenceGroup.fromJson(Map<String, dynamic> json) =>
      AiPreferenceGroup(
        id: json['id'] as String? ?? '',
        name: json['name'] as String? ?? '',
        intent: json['intent'] as String? ?? '',
        prompt: json['prompt'] as String? ?? '',
        source: AiRecommendationSource.values.firstWhere(
          (source) => source.name == json['source'],
          orElse: () => AiRecommendationSource.recommendation,
        ),
        searchQueries:
            (json['search_queries'] as List?)
                ?.map((query) => query.toString())
                .toList() ??
            const [],
        resultCount: _asInt(json['result_count']) ?? 8,
        minimumDurationSeconds: _asInt(json['minimum_duration_seconds']) ?? 900,
        enabled: json['enabled'] as bool? ?? true,
      );

  final String id;
  final String name;
  final String intent;
  final String prompt;
  final AiRecommendationSource source;
  final List<String> searchQueries;
  final int resultCount;
  final int minimumDurationSeconds;
  final bool enabled;

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'intent': intent,
    'prompt': prompt,
    'source': source.name,
    'search_queries': searchQueries,
    'result_count': resultCount,
    'minimum_duration_seconds': minimumDurationSeconds,
    'enabled': enabled,
  };

  AiPreferenceGroup copyWith({
    String? id,
    String? name,
    String? intent,
    String? prompt,
    AiRecommendationSource? source,
    List<String>? searchQueries,
    int? resultCount,
    int? minimumDurationSeconds,
    bool? enabled,
  }) => AiPreferenceGroup(
    id: id ?? this.id,
    name: name ?? this.name,
    intent: intent ?? this.intent,
    prompt: prompt ?? this.prompt,
    source: source ?? this.source,
    searchQueries: searchQueries ?? this.searchQueries,
    resultCount: resultCount ?? this.resultCount,
    minimumDurationSeconds:
        minimumDurationSeconds ?? this.minimumDurationSeconds,
    enabled: enabled ?? this.enabled,
  );
}

class AiRecommendationCandidate {
  const AiRecommendationCandidate({
    required this.bvid,
    this.aid,
    this.cid,
    required this.title,
    this.cover,
    required this.duration,
    this.pubdate,
    this.ownerMid,
    required this.ownerName,
    this.view,
    this.like,
    this.danmu,
    required this.isFollowed,
    this.sourceReason,
  });

  factory AiRecommendationCandidate.fromVideo(BaseRcmdVideoItemModel video) =>
      AiRecommendationCandidate(
        bvid: video.bvid!,
        aid: video.aid,
        cid: video.cid,
        title: video.title,
        cover: video.cover,
        duration: video.duration,
        pubdate: video.pubdate,
        ownerMid: video.owner.mid,
        ownerName: video.owner.name ?? '',
        view: video.stat.view,
        like: video.stat.like,
        danmu: video.stat.danmu,
        isFollowed: video.isFollowed,
        sourceReason: video.rcmdReason,
      );

  factory AiRecommendationCandidate.fromJson(Map<String, dynamic> json) =>
      AiRecommendationCandidate(
        bvid: json['bvid'] as String,
        aid: _asInt(json['aid']),
        cid: _asInt(json['cid']),
        title: json['title'] as String,
        cover: json['cover'] as String?,
        duration: _asInt(json['duration']) ?? 0,
        pubdate: _asInt(json['pubdate']),
        ownerMid: _asInt(json['owner_mid']),
        ownerName: json['owner_name'] as String? ?? '',
        view: _asInt(json['view']),
        like: _asInt(json['like']),
        danmu: _asInt(json['danmu']),
        isFollowed: json['is_followed'] as bool? ?? false,
        sourceReason: json['source_reason'] as String?,
      );

  final String bvid;
  final int? aid;
  final int? cid;
  final String title;
  final String? cover;
  final int duration;
  final int? pubdate;
  final int? ownerMid;
  final String ownerName;
  final int? view;
  final int? like;
  final int? danmu;
  final bool isFollowed;
  final String? sourceReason;

  Map<String, dynamic> toJson() => {
    'bvid': bvid,
    'aid': aid,
    'cid': cid,
    'title': title,
    'cover': cover,
    'duration': duration,
    'pubdate': pubdate,
    'owner_mid': ownerMid,
    'owner_name': ownerName,
    'view': view,
    'like': like,
    'danmu': danmu,
    'is_followed': isFollowed,
    'source_reason': sourceReason,
  };

  Map<String, dynamic> toPromptJson() => {
    'bvid': bvid,
    'title': title,
    'up': ownerName,
    'duration_seconds': duration,
    'published_at_unix': pubdate,
    'view': view,
    'like': like,
    'danmu': danmu,
    'followed_up': isFollowed,
    'source_reason': sourceReason,
  };
}

class AiRecommendationDecision {
  const AiRecommendationDecision({
    required this.bvid,
    required this.score,
    required this.reason,
    this.summary,
    this.tags = const [],
  });

  factory AiRecommendationDecision.fromJson(Map<String, dynamic> json) {
    final score = (_asNum(json['score']) ?? 0).clamp(0, 100).round();
    return AiRecommendationDecision(
      bvid: json['bvid'] as String,
      score: score,
      reason: json['reason'] as String? ?? '',
      summary: json['summary'] as String?,
      tags:
          (json['tags'] as List?)?.map((item) => item.toString()).toList() ??
          const [],
    );
  }

  final String bvid;
  final int score;
  final String reason;
  final String? summary;
  final List<String> tags;
}

class AiRecommendationItem {
  const AiRecommendationItem({
    required this.candidate,
    required this.score,
    required this.reason,
    this.summary,
    this.tags = const [],
  });

  factory AiRecommendationItem.fromDecision(
    AiRecommendationCandidate candidate,
    AiRecommendationDecision decision,
  ) => AiRecommendationItem(
    candidate: candidate,
    score: decision.score,
    reason: decision.reason,
    summary: decision.summary,
    tags: decision.tags,
  );

  factory AiRecommendationItem.fromJson(Map<String, dynamic> json) =>
      AiRecommendationItem(
        candidate: AiRecommendationCandidate.fromJson(json),
        score: (_asNum(json['score']) ?? 0).clamp(0, 100).round(),
        reason: json['reason'] as String? ?? '',
        summary: json['summary'] as String?,
        tags:
            (json['tags'] as List?)?.map((item) => item.toString()).toList() ??
            const [],
      );

  final AiRecommendationCandidate candidate;
  final int score;
  final String reason;
  final String? summary;
  final List<String> tags;

  Map<String, dynamic> toJson() => {
    ...candidate.toJson(),
    'score': score,
    'reason': reason,
    'summary': summary,
    'tags': tags,
  };
}

class AiRecommendationGroupFeed {
  const AiRecommendationGroupFeed({
    required this.group,
    required this.items,
    this.pipeline = const {},
    this.error,
  });

  factory AiRecommendationGroupFeed.fromJson(Map<String, dynamic> json) =>
      AiRecommendationGroupFeed(
        group: AiPreferenceGroup.fromJson(json),
        items: (json['items'] as List? ?? const [])
            .map(
              (item) => AiRecommendationItem.fromJson(
                Map<String, dynamic>.from(item as Map),
              ),
            )
            .toList(),
        pipeline: json['pipeline'] is Map
            ? Map<String, dynamic>.from(json['pipeline'] as Map)
            : const {},
        error: json['error'] as String?,
      );

  final AiPreferenceGroup group;
  final List<AiRecommendationItem> items;
  final Map<String, dynamic> pipeline;
  final String? error;

  Map<String, dynamic> toJson() => {
    ...group.toJson(),
    'pipeline': pipeline,
    'error': error,
    'items': items.map((item) => item.toJson()).toList(),
  };
}

class AiRecommendationFeed {
  const AiRecommendationFeed({
    this.schemaVersion = 1,
    required this.generatedAt,
    required this.source,
    required this.preferenceSnapshot,
    required this.items,
    this.groups = const [],
    this.isGrouped = false,
  });

  factory AiRecommendationFeed.fromJson(Map<String, dynamic> json) {
    final schemaVersion = _asInt(json['schema_version']) ?? 0;
    if (schemaVersion != 1) {
      throw const FormatException('不支持的 AI 推荐 JSON 版本');
    }
    final generatedAt = DateTime.tryParse(
      json['generated_at'] as String? ?? '',
    );
    if (generatedAt == null) {
      throw const FormatException('AI 推荐 JSON 缺少 generated_at');
    }
    return AiRecommendationFeed(
      schemaVersion: schemaVersion,
      generatedAt: generatedAt,
      source: json['source'] as String? ?? 'vps',
      preferenceSnapshot: json['preference_snapshot'] as String? ?? '',
      items: (json['items'] as List? ?? const [])
          .map(
            (item) => AiRecommendationItem.fromJson(
              Map<String, dynamic>.from(item as Map),
            ),
          )
          .toList(),
      groups: (json['groups'] as List? ?? const [])
          .whereType<Map>()
          .map(
            (group) => AiRecommendationGroupFeed.fromJson(
              Map<String, dynamic>.from(group),
            ),
          )
          .toList(),
      isGrouped: json.containsKey('groups'),
    );
  }

  final int schemaVersion;
  final DateTime generatedAt;
  final String source;
  final String preferenceSnapshot;
  final List<AiRecommendationItem> items;
  final List<AiRecommendationGroupFeed> groups;
  final bool isGrouped;

  List<AiRecommendationGroupFeed> get effectiveGroups {
    if (groups.isNotEmpty) return groups;
    if (isGrouped) return const [];
    return [
      AiRecommendationGroupFeed(
        group: AiPreferenceGroup(
          id: 'default',
          name: '每日精选',
          intent: preferenceSnapshot,
          prompt: preferenceSnapshot,
          source: AiRecommendationSource.recommendation,
        ),
        items: items,
      ),
    ];
  }

  Map<String, dynamic> toJson() => {
    'schema_version': schemaVersion,
    'generated_at': generatedAt.toUtc().toIso8601String(),
    'source': source,
    'preference_snapshot': preferenceSnapshot,
    'items': items.map((item) => item.toJson()).toList(),
    if (isGrouped || groups.isNotEmpty)
      'groups': groups.map((group) => group.toJson()).toList(),
  };
}

int? _asInt(Object? value) => switch (value) {
  int value => value,
  num value => value.round(),
  String value => int.tryParse(value),
  _ => null,
};

num? _asNum(Object? value) => switch (value) {
  num value => value,
  String value => num.tryParse(value),
  _ => null,
};
