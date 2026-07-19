import 'dart:async';

import 'package:PiliPlus/features/ai_recommendation/model.dart';
import 'package:PiliPlus/features/ai_recommendation/preferences.dart';
import 'package:PiliPlus/features/ai_recommendation/remote_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';

class AiPreferenceGroupsPage extends StatefulWidget {
  const AiPreferenceGroupsPage({super.key});

  @override
  State<AiPreferenceGroupsPage> createState() => _AiPreferenceGroupsPageState();
}

class _AiPreferenceGroupsPageState extends State<AiPreferenceGroupsPage> {
  final _client = AiRecommendationRemoteClient();
  List<AiPreferenceGroup> _groups = const [];
  bool _loading = true;
  bool _generating = false;
  bool _polling = false;
  String? _generationStatus;
  String? _error;

  String get _feedUrl => AiRecommendationPreferences.remoteUrl.trim();

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('VPS 偏好组'),
      actions: [
        IconButton(
          tooltip: '立即重新生成',
          onPressed: _generating ? null : _generate,
          icon: _generating
              ? const SizedBox.square(
                  dimension: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.play_arrow),
        ),
        IconButton(
          tooltip: '刷新',
          onPressed: _loading ? null : _load,
          icon: const Icon(Icons.refresh),
        ),
      ],
    ),
    floatingActionButton: FloatingActionButton.extended(
      onPressed: _editNew,
      icon: const Icon(Icons.add),
      label: const Text('新建偏好组'),
    ),
    body: _body,
  );

  Widget get _body {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.cloud_off_outlined, size: 48),
              const SizedBox(height: 12),
              Text(_error!, textAlign: TextAlign.center),
              const SizedBox(height: 16),
              FilledButton(onPressed: _load, child: const Text('重试')),
            ],
          ),
        ),
      );
    }
    if (_groups.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(32),
          child: Text('还没有偏好组。点击右下角，用一句话创建第一个组。'),
        ),
      );
    }
    return ListView(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 100),
      children: [
        const Card(
          child: Padding(
            padding: EdgeInsets.all(12),
            child: Text(
              '每个组会独立筛选、评分和输出。推荐流适合发现陌生内容；'
              '搜索适合明确主题；混合模式会合并两者并去重。',
            ),
          ),
        ),
        if (_generationStatus != null)
          Card(
            child: ListTile(
              leading: _generating
                  ? const CircularProgressIndicator()
                  : const Icon(Icons.check_circle_outline),
              title: Text(_generationStatus!),
              subtitle: const Text('生成期间旧 feed 会继续可用'),
            ),
          ),
        ..._groups.map(_groupCard),
      ],
    );
  }

  Widget _groupCard(AiPreferenceGroup group) => Card(
    child: Padding(
      padding: const EdgeInsets.fromLTRB(14, 10, 8, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  group.name,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
              Switch(
                value: group.enabled,
                onChanged: (value) =>
                    _save(group.copyWith(enabled: value), existing: true),
              ),
              IconButton(
                tooltip: '编辑',
                onPressed: () => _edit(group),
                icon: const Icon(Icons.edit_outlined),
              ),
              IconButton(
                tooltip: '删除',
                onPressed: () => _delete(group),
                icon: const Icon(Icons.delete_outline),
              ),
            ],
          ),
          Text(group.intent),
          const SizedBox(height: 8),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              Chip(
                avatar: const Icon(Icons.source_outlined, size: 16),
                label: Text(_sourceLabel(group.source)),
                visualDensity: VisualDensity.compact,
              ),
              Chip(
                label: Text('≥${group.minimumDurationSeconds ~/ 60} 分钟'),
                visualDensity: VisualDensity.compact,
              ),
              Chip(
                label: Text('${group.resultCount} 条'),
                visualDensity: VisualDensity.compact,
              ),
              if (group.searchQueries.isNotEmpty)
                Chip(
                  label: Text('${group.searchQueries.length} 个搜索词'),
                  visualDensity: VisualDensity.compact,
                ),
            ],
          ),
        ],
      ),
    ),
  );

  Future<void> _load() async {
    if (_feedUrl.isEmpty) {
      setState(() {
        _loading = false;
        _error = '请先在上一页填写 VPS feed.json 地址并保存';
      });
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final groups = await _client.listGroups(_feedUrl);
      final status = await _client.status(_feedUrl);
      if (mounted) {
        setState(() {
          _groups = groups;
          _generating = status['running'] == true;
          _generationStatus = _generating ? 'VPS 正在生成分组推荐' : null;
        });
        if (_generating) unawaited(_pollGeneration());
      }
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _editNew() async {
    final group = await showDialog<AiPreferenceGroup>(
      context: context,
      builder: (context) =>
          _PreferenceGroupEditor(feedUrl: _feedUrl, client: _client),
    );
    if (group != null) await _save(group, existing: false);
  }

  Future<void> _edit(AiPreferenceGroup current) async {
    final group = await showDialog<AiPreferenceGroup>(
      context: context,
      builder: (context) => _PreferenceGroupEditor(
        feedUrl: _feedUrl,
        client: _client,
        initial: current,
      ),
    );
    if (group != null) await _save(group, existing: true);
  }

  Future<void> _save(AiPreferenceGroup group, {required bool existing}) async {
    try {
      final saved = existing
          ? await _client.update(_feedUrl, group)
          : await _client.create(_feedUrl, group);
      if (!mounted) return;
      setState(() {
        final groups = [..._groups];
        final index = groups.indexWhere((item) => item.id == saved.id);
        if (index < 0) {
          groups.add(saved);
        } else {
          groups[index] = saved;
        }
        _groups = groups;
      });
      SmartDialog.showToast('偏好组已保存');
    } catch (error) {
      SmartDialog.showToast(error.toString());
    }
  }

  Future<void> _delete(AiPreferenceGroup group) async {
    final confirmed =
        await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: Text('删除“${group.name}”？'),
            content: const Text('会删除这个组的提示词和来源设置，不影响其他组。'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('删除'),
              ),
            ],
          ),
        ) ??
        false;
    if (!confirmed) return;
    try {
      await _client.delete(_feedUrl, group.id);
      if (mounted) {
        setState(
          () => _groups = _groups.where((item) => item.id != group.id).toList(),
        );
      }
      SmartDialog.showToast('已删除');
    } catch (error) {
      SmartDialog.showToast(error.toString());
    }
  }

  Future<void> _generate() async {
    setState(() => _generating = true);
    try {
      await _client.generate(_feedUrl);
      if (mounted) {
        setState(() => _generationStatus = 'VPS 正在生成分组推荐');
      }
      SmartDialog.showToast('VPS 已开始后台生成，完成前仍显示旧结果');
      unawaited(_pollGeneration());
    } catch (error) {
      if (mounted) setState(() => _generating = false);
      SmartDialog.showToast(error.toString());
    }
  }

  Future<void> _pollGeneration() async {
    if (_polling) return;
    _polling = true;
    try {
      while (mounted && _generating) {
        await Future<void>.delayed(const Duration(seconds: 10));
        if (!mounted) return;
        try {
          final status = await _client.status(_feedUrl);
          if (status['running'] == true) continue;
          final succeeded = status['exit_code'] == 0;
          setState(() {
            _generating = false;
            _generationStatus = succeeded ? 'VPS 分组推荐已生成' : 'VPS 生成失败';
          });
          SmartDialog.showToast(
            succeeded ? '分组推荐已生成，可以返回结果页刷新' : 'VPS 生成失败，请稍后重试',
          );
        } catch (_) {
          // A temporary network error should not cancel a running VPS job.
        }
      }
    } finally {
      _polling = false;
    }
  }
}

class _PreferenceGroupEditor extends StatefulWidget {
  const _PreferenceGroupEditor({
    required this.feedUrl,
    required this.client,
    this.initial,
  });

  final String feedUrl;
  final AiRecommendationRemoteClient client;
  final AiPreferenceGroup? initial;

  @override
  State<_PreferenceGroupEditor> createState() => _PreferenceGroupEditorState();
}

class _PreferenceGroupEditorState extends State<_PreferenceGroupEditor> {
  final _formKey = GlobalKey<FormState>();
  late final _name = TextEditingController(text: widget.initial?.name);
  late final _intent = TextEditingController(text: widget.initial?.intent);
  late final _prompt = TextEditingController(text: widget.initial?.prompt);
  late final _queries = TextEditingController(
    text: widget.initial?.searchQueries.join('\n'),
  );
  late final _duration = TextEditingController(
    text: ((widget.initial?.minimumDurationSeconds ?? 900) ~/ 60).toString(),
  );
  late final _resultCount = TextEditingController(
    text: (widget.initial?.resultCount ?? 8).toString(),
  );
  late AiRecommendationSource _source =
      widget.initial?.source ?? AiRecommendationSource.recommendation;
  late bool _enabled = widget.initial?.enabled ?? true;
  bool _expanding = false;

  @override
  void dispose() {
    _name.dispose();
    _intent.dispose();
    _prompt.dispose();
    _queries.dispose();
    _duration.dispose();
    _resultCount.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.initial == null ? '新建偏好组' : '编辑偏好组'),
    content: SizedBox(
      width: 560,
      child: Form(
        key: _formKey,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextFormField(
                controller: _intent,
                minLines: 2,
                maxLines: 4,
                decoration: const InputDecoration(
                  labelText: '一句话描述想看什么',
                  hintText: '例如：优质游戏长视频，不要标题党和大惊小怪',
                  border: OutlineInputBorder(),
                ),
                validator: (value) =>
                    value?.trim().isEmpty == true ? '请描述偏好' : null,
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<AiRecommendationSource>(
                initialValue: _source,
                decoration: const InputDecoration(
                  labelText: '候选来源',
                  border: OutlineInputBorder(),
                ),
                items: AiRecommendationSource.values
                    .map(
                      (source) => DropdownMenuItem(
                        value: source,
                        child: Text(_sourceLabel(source)),
                      ),
                    )
                    .toList(),
                onChanged: (value) => setState(() => _source = value!),
              ),
              const SizedBox(height: 10),
              Align(
                alignment: Alignment.centerLeft,
                child: FilledButton.tonalIcon(
                  onPressed: _expanding ? null : _expand,
                  icon: _expanding
                      ? const SizedBox.square(
                          dimension: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.auto_awesome, size: 18),
                  label: const Text('AI 生成评分标准与搜索词'),
                ),
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _name,
                decoration: const InputDecoration(
                  labelText: '组名',
                  border: OutlineInputBorder(),
                ),
                validator: (value) =>
                    value?.trim().isEmpty == true ? '请填写组名' : null,
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _prompt,
                minLines: 5,
                maxLines: 10,
                decoration: const InputDecoration(
                  labelText: '完整评分提示词（可以继续手改）',
                  alignLabelWithHint: true,
                  border: OutlineInputBorder(),
                ),
                validator: (value) =>
                    value?.trim().isEmpty == true ? '请先生成或填写评分提示词' : null,
              ),
              if (_source != AiRecommendationSource.recommendation) ...[
                const SizedBox(height: 12),
                TextFormField(
                  controller: _queries,
                  minLines: 3,
                  maxLines: 8,
                  decoration: const InputDecoration(
                    labelText: '搜索词（每行一个）',
                    alignLabelWithHint: true,
                    border: OutlineInputBorder(),
                  ),
                  validator: (value) =>
                      value?.trim().isEmpty == true ? '搜索来源至少需要一个搜索词' : null,
                ),
              ],
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: TextFormField(
                      controller: _duration,
                      keyboardType: TextInputType.number,
                      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                      decoration: const InputDecoration(
                        labelText: '最低时长（分钟）',
                        border: OutlineInputBorder(),
                      ),
                      validator: (value) => _numberValidator(value, 1, 240),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: TextFormField(
                      controller: _resultCount,
                      keyboardType: TextInputType.number,
                      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                      decoration: const InputDecoration(
                        labelText: '推荐条数',
                        border: OutlineInputBorder(),
                      ),
                      validator: (value) => _numberValidator(value, 1, 30),
                    ),
                  ),
                ],
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('启用这个组'),
                value: _enabled,
                onChanged: (value) => setState(() => _enabled = value),
              ),
            ],
          ),
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('取消'),
      ),
      FilledButton(onPressed: _submit, child: const Text('保存')),
    ],
  );

  Future<void> _expand() async {
    if (_intent.text.trim().isEmpty) {
      SmartDialog.showToast('请先写一句偏好');
      return;
    }
    setState(() => _expanding = true);
    try {
      final proposal = await widget.client.expand(
        feedUrl: widget.feedUrl,
        intent: _intent.text.trim(),
        source: _source,
      );
      if (!mounted) return;
      setState(() {
        _name.text = proposal.name;
        _prompt.text = proposal.prompt;
        _queries.text = proposal.searchQueries.join('\n');
      });
    } catch (error) {
      SmartDialog.showToast(error.toString());
    } finally {
      if (mounted) setState(() => _expanding = false);
    }
  }

  Future<void> _submit() async {
    if (_intent.text.trim().isEmpty) {
      _formKey.currentState?.validate();
      return;
    }
    if (_prompt.text.trim().isEmpty || _name.text.trim().isEmpty) {
      await _expand();
      if (_prompt.text.trim().isEmpty || _name.text.trim().isEmpty) return;
    }
    if (_formKey.currentState?.validate() != true) return;
    Navigator.pop(
      context,
      AiPreferenceGroup(
        id: widget.initial?.id ?? '',
        name: _name.text.trim(),
        intent: _intent.text.trim(),
        prompt: _prompt.text.trim(),
        source: _source,
        searchQueries: _queries.text
            .split('\n')
            .map((query) => query.trim())
            .where((query) => query.isNotEmpty)
            .toSet()
            .toList(),
        resultCount: int.parse(_resultCount.text),
        minimumDurationSeconds: int.parse(_duration.text) * 60,
        enabled: _enabled,
      ),
    );
  }

  String? _numberValidator(String? value, int min, int max) {
    final number = int.tryParse(value ?? '');
    return number != null && number >= min && number <= max
        ? null
        : '范围 $min-$max';
  }
}

String _sourceLabel(AiRecommendationSource source) => switch (source) {
  AiRecommendationSource.recommendation => '首页推荐流',
  AiRecommendationSource.search => 'B 站搜索',
  AiRecommendationSource.hybrid => '推荐流 + 搜索',
};
