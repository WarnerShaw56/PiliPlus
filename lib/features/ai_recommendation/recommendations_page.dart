import 'package:PiliPlus/common/widgets/flutter/refresh_indicator.dart';
import 'package:PiliPlus/common/widgets/image/network_img_layer.dart';
import 'package:PiliPlus/features/ai_recommendation/model.dart';
import 'package:PiliPlus/features/ai_recommendation/repository.dart';
import 'package:PiliPlus/features/ai_recommendation/service.dart';
import 'package:PiliPlus/http/search.dart';
import 'package:PiliPlus/models_new/video/video_detail/dimension.dart';
import 'package:PiliPlus/utils/page_utils.dart';
import 'package:flutter/material.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';

class AiRecommendationsPage extends StatefulWidget {
  const AiRecommendationsPage({super.key});

  @override
  State<AiRecommendationsPage> createState() => _AiRecommendationsPageState();
}

class _AiRecommendationsPageState extends State<AiRecommendationsPage> {
  AiRecommendationFeed? _feed;
  bool _running = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _feed = AiRecommendationRepository.read();
    _error = AiRecommendationRepository.lastError;
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('今日 AI 精选'),
      actions: [
        IconButton(
          tooltip: '配置',
          onPressed: () => Get.toNamed('/aiRecommendationSettings'),
          icon: const Icon(Icons.tune),
        ),
        IconButton(
          tooltip: '立即更新',
          onPressed: _running ? null : _refresh,
          icon: _running
              ? const SizedBox.square(
                  dimension: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.refresh),
        ),
      ],
    ),
    body: AiRecommendationFeedView(
      feed: _feed,
      error: _error,
      running: _running,
      onRefresh: _refresh,
    ),
  );

  Future<void> _refresh() async {
    if (_running) return;
    setState(() => _running = true);
    try {
      final feed = await AiRecommendationService().refresh();
      if (mounted) {
        setState(() {
          _feed = feed;
          _error = null;
        });
      }
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
      SmartDialog.showToast(error.toString());
    } finally {
      if (mounted) setState(() => _running = false);
    }
  }
}

class AiRecommendationFeedView extends StatefulWidget {
  const AiRecommendationFeedView({
    super.key,
    required this.feed,
    required this.error,
    required this.running,
    required this.onRefresh,
    this.scrollController,
    this.embedded = false,
  });

  final AiRecommendationFeed? feed;
  final String? error;
  final bool running;
  final Future<void> Function() onRefresh;
  final ScrollController? scrollController;
  final bool embedded;

  @override
  State<AiRecommendationFeedView> createState() =>
      _AiRecommendationFeedViewState();
}

class _AiRecommendationFeedViewState extends State<AiRecommendationFeedView> {
  String? _selectedGroupId;

  @override
  Widget build(BuildContext context) {
    final feed = widget.feed;
    final child = feed == null ? _empty : _feedBody(feed);
    return refreshIndicator(onRefresh: widget.onRefresh, child: child);
  }

  Widget get _empty => ListView(
    controller: widget.scrollController,
    physics: const AlwaysScrollableScrollPhysics(),
    padding: const EdgeInsets.all(32),
    children: [
      const SizedBox(height: 72),
      const Icon(Icons.auto_awesome_outlined, size: 52),
      const SizedBox(height: 16),
      Text(widget.error ?? '还没有生成 AI 精选', textAlign: TextAlign.center),
      const SizedBox(height: 16),
      Center(
        child: Wrap(
          spacing: 10,
          runSpacing: 10,
          alignment: WrapAlignment.center,
          children: [
            FilledButton.icon(
              onPressed: widget.running ? null : widget.onRefresh,
              icon: widget.running
                  ? const SizedBox.square(
                      dimension: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.refresh),
              label: const Text('立即获取'),
            ),
            OutlinedButton.icon(
              onPressed: () => Get.toNamed('/aiRecommendationSettings'),
              icon: const Icon(Icons.tune),
              label: const Text('配置'),
            ),
          ],
        ),
      ),
    ],
  );

  Widget _feedBody(AiRecommendationFeed feed) {
    final groups = feed.effectiveGroups;
    if (feed.isGrouped && groups.isEmpty) {
      return ListView(
        controller: widget.scrollController,
        physics: const AlwaysScrollableScrollPhysics(),
        padding: _padding,
        children: [
          _header(feed, 0),
          if (widget.error != null) _loadError,
          const SizedBox(height: 24),
          const Center(child: Text('暂无启用的偏好组，请到配置页新建或启用一个组')),
        ],
      );
    }
    final group = groups.firstWhere(
      (item) => item.group.id == _selectedGroupId,
      orElse: () => groups.first,
    );
    return ListView(
      controller: widget.scrollController,
      physics: const AlwaysScrollableScrollPhysics(),
      padding: _padding,
      children: [
        _header(feed, group.items.length),
        if (widget.error != null) _loadError,
        if (groups.length > 1) ...[
          const SizedBox(height: 8),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: groups
                  .map(
                    (item) => Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: ChoiceChip(
                        selected: item.group.id == group.group.id,
                        label: Text('${item.group.name} ${item.items.length}'),
                        onSelected: (_) =>
                            setState(() => _selectedGroupId = item.group.id),
                      ),
                    ),
                  )
                  .toList(),
            ),
          ),
        ],
        const SizedBox(height: 8),
        _groupHeader(group),
        if (group.error?.isNotEmpty == true)
          Card(
            color: ColorScheme.of(context).errorContainer,
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Text('本组生成失败：${group.error}'),
            ),
          ),
        if (group.items.isEmpty && group.error?.isNotEmpty != true)
          const Padding(
            padding: EdgeInsets.all(24),
            child: Center(child: Text('这个组暂时没有合格推荐')),
          ),
        ...group.items.map(_itemCard),
      ],
    );
  }

  EdgeInsets get _padding => EdgeInsets.fromLTRB(
    widget.embedded ? 0 : 12,
    8,
    widget.embedded ? 0 : 12,
    100,
  );

  Widget get _loadError => Card(
    color: ColorScheme.of(context).errorContainer,
    child: Padding(
      padding: const EdgeInsets.all(12),
      child: Text('刷新失败，继续显示上次结果：${widget.error}'),
    ),
  );

  Widget _header(AiRecommendationFeed feed, int itemCount) {
    final time = feed.generatedAt.toLocal();
    final source = feed.source == 'local' ? '本机生成' : 'VPS';
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
        child: Row(
          children: [
            const Icon(Icons.auto_awesome),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                '$source · ${time.year}-'
                '${time.month.toString().padLeft(2, '0')}-'
                '${time.day.toString().padLeft(2, '0')} '
                '${time.hour.toString().padLeft(2, '0')}:'
                '${time.minute.toString().padLeft(2, '0')} · '
                '$itemCount 条',
              ),
            ),
            if (widget.embedded) ...[
              IconButton(
                tooltip: '配置 AI 精选',
                onPressed: () => Get.toNamed('/aiRecommendationSettings'),
                icon: const Icon(Icons.tune),
              ),
              IconButton(
                tooltip: '刷新 AI 精选',
                onPressed: widget.running ? null : widget.onRefresh,
                icon: widget.running
                    ? const SizedBox.square(
                        dimension: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.refresh),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _groupHeader(AiRecommendationGroupFeed group) {
    final source = switch (group.group.source) {
      AiRecommendationSource.recommendation => '首页推荐流',
      AiRecommendationSource.search => 'B 站搜索',
      AiRecommendationSource.hybrid => '推荐流 + 搜索',
    };
    final pipeline = group.pipeline;
    final sourceCandidates = pipeline['source_candidates'];
    final preliminary = pipeline['preliminary_ranked'];
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    group.group.name,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                Chip(label: Text(source), visualDensity: VisualDensity.compact),
              ],
            ),
            if (group.group.intent.isNotEmpty) Text(group.group.intent),
            if (sourceCandidates != null || preliminary != null) ...[
              const SizedBox(height: 6),
              Text(
                '候选 ${sourceCandidates ?? '-'} · AI 初筛 '
                '${preliminary ?? '-'}',
                style: TextStyle(color: ColorScheme.of(context).outline),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _itemCard(AiRecommendationItem item) {
    final candidate = item.candidate;
    final colorScheme = ColorScheme.of(context);
    return Card(
      clipBehavior: Clip.hardEdge,
      child: InkWell(
        onTap: () => _openVideo(item),
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: NetworkImgLayer(
                      src: candidate.cover,
                      width: 132,
                      height: 74,
                      type: .emote,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          candidate.title,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontWeight: FontWeight.w600),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          candidate.ownerName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(color: colorScheme.outline),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 9,
                      vertical: 5,
                    ),
                    decoration: BoxDecoration(
                      color: colorScheme.primaryContainer,
                      borderRadius: BorderRadius.circular(99),
                    ),
                    child: Text(
                      '${item.score}',
                      style: TextStyle(
                        color: colorScheme.onPrimaryContainer,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Text(item.reason),
              if (item.summary?.isNotEmpty == true) ...[
                const SizedBox(height: 5),
                Text(
                  item.summary!,
                  style: TextStyle(color: colorScheme.outline),
                ),
              ],
              if (item.tags.isNotEmpty) ...[
                const SizedBox(height: 8),
                Wrap(
                  spacing: 6,
                  runSpacing: 4,
                  children: item.tags
                      .map(
                        (tag) =>
                            Chip(label: Text(tag), visualDensity: .compact),
                      )
                      .toList(),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _openVideo(AiRecommendationItem item) async {
    final candidate = item.candidate;
    var cid = candidate.cid;
    Dimension? dimension;
    if (cid == null) {
      final result = await SearchHttp.ab2cWithDimension(
        aid: candidate.aid,
        bvid: candidate.bvid,
      );
      cid = result?.cid;
      dimension = result?.dimension;
    }
    if (cid == null) {
      SmartDialog.showToast('无法获取视频 cid');
      return;
    }
    PageUtils.toVideoPage(
      aid: candidate.aid,
      bvid: candidate.bvid,
      cid: cid,
      cover: candidate.cover,
      title: candidate.title,
      dimension: dimension,
    );
  }
}
