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

  @override
  void initState() {
    super.initState();
    _feed = AiRecommendationRepository.read();
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
    body: _feed == null
        ? _empty
        : ListView(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 100),
            children: [
              _header(_feed!),
              const SizedBox(height: 8),
              ..._feed!.items.map(_itemCard),
            ],
          ),
  );

  Widget get _empty => Center(
    child: Padding(
      padding: const EdgeInsets.all(32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.auto_awesome_outlined, size: 52),
          const SizedBox(height: 16),
          Text(AiRecommendationRepository.lastError ?? '还没有生成 AI 精选'),
          const SizedBox(height: 16),
          FilledButton(
            onPressed: () => Get.toNamed('/aiRecommendationSettings'),
            child: const Text('去配置'),
          ),
        ],
      ),
    ),
  );

  Widget _header(AiRecommendationFeed feed) {
    final time = feed.generatedAt.toLocal();
    final source = feed.source == 'local' ? '本机生成' : 'VPS';
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
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
                '${time.minute.toString().padLeft(2, '0')}',
              ),
            ),
            Text('${feed.items.length} 条'),
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

  Future<void> _refresh() async {
    setState(() => _running = true);
    try {
      final feed = await AiRecommendationService().refresh();
      if (mounted) setState(() => _feed = feed);
    } catch (error) {
      SmartDialog.showToast(error.toString());
    } finally {
      if (mounted) setState(() => _running = false);
    }
  }
}
