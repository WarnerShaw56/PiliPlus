import 'package:PiliPlus/features/ai_recommendation/model.dart';
import 'package:PiliPlus/features/ai_recommendation/preferences.dart';
import 'package:PiliPlus/features/ai_recommendation/secret_store.dart';
import 'package:PiliPlus/features/ai_recommendation/service.dart';
import 'package:PiliPlus/utils/storage.dart';
import 'package:PiliPlus/utils/storage_key.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';

class AiRecommendationSettingsPage extends StatefulWidget {
  const AiRecommendationSettingsPage({super.key});

  @override
  State<AiRecommendationSettingsPage> createState() =>
      _AiRecommendationSettingsPageState();
}

class _AiRecommendationSettingsPageState
    extends State<AiRecommendationSettingsPage> {
  final _formKey = GlobalKey<FormState>();
  late final _endpointController = TextEditingController(
    text: AiRecommendationPreferences.endpoint,
  );
  late final _modelController = TextEditingController(
    text: AiRecommendationPreferences.model,
  );
  late final _preferenceController = TextEditingController(
    text: AiRecommendationPreferences.preference,
  );
  late final _candidateController = TextEditingController(
    text: AiRecommendationPreferences.candidateCount.toString(),
  );
  late final _resultController = TextEditingController(
    text: AiRecommendationPreferences.resultCount.toString(),
  );
  late final _remoteUrlController = TextEditingController(
    text: AiRecommendationPreferences.remoteUrl,
  );
  final _apiKeyController = TextEditingController();

  late bool _enabled = AiRecommendationPreferences.enabled;
  late bool _replaceHome = AiRecommendationPreferences.replacesHome;
  late AiRecommendationMode _mode = AiRecommendationPreferences.mode;
  late AiApiFormat _apiFormat = AiRecommendationPreferences.apiFormat;
  late int _dailyHour = AiRecommendationPreferences.dailyHour;
  bool _obscureApiKey = true;
  bool _running = false;

  @override
  void initState() {
    super.initState();
    _loadApiKey();
  }

  Future<void> _loadApiKey() async {
    try {
      final value = await AiRecommendationSecretStore.readApiKey();
      if (mounted) _apiKeyController.text = value;
    } catch (error) {
      if (mounted) SmartDialog.showToast('读取 API Key 失败：$error');
    }
  }

  @override
  void dispose() {
    _endpointController.dispose();
    _modelController.dispose();
    _preferenceController.dispose();
    _candidateController.dispose();
    _resultController.dispose();
    _remoteUrlController.dispose();
    _apiKeyController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('AI 每日精选'),
      actions: [
        IconButton(
          tooltip: '查看结果',
          onPressed: () => Get.toNamed('/aiRecommendations'),
          icon: const Icon(Icons.auto_awesome_outlined),
        ),
      ],
    ),
    body: Form(
      key: _formKey,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 120),
        children: [
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            value: _enabled,
            onChanged: (value) => setState(() => _enabled = value),
            title: const Text('每日自动更新'),
            subtitle: const Text('在设定时间后，应用当天首次运行时自动补跑'),
            secondary: const Icon(Icons.schedule_outlined),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            value: _replaceHome,
            onChanged: (value) => setState(() => _replaceHome = value),
            title: const Text('用 AI 精选替换首页推荐'),
            subtitle: const Text(
              '首页“推荐”页将只显示 AI 分组结果，不再加载短视频推荐流；'
              '若曾隐藏该页签会自动恢复；与每日自动更新互不影响，重启应用后生效',
            ),
            secondary: const Icon(Icons.home_outlined),
          ),
          const SizedBox(height: 8),
          DropdownButtonFormField<AiRecommendationMode>(
            initialValue: _mode,
            decoration: const InputDecoration(
              labelText: '执行方式',
              border: OutlineInputBorder(),
            ),
            items: const [
              DropdownMenuItem(
                value: AiRecommendationMode.local,
                child: Text('本机抓候选并调用 AI'),
              ),
              DropdownMenuItem(
                value: AiRecommendationMode.vps,
                child: Text('从 VPS 拉取已生成 JSON'),
              ),
            ],
            onChanged: (value) => setState(() => _mode = value!),
          ),
          const SizedBox(height: 16),
          if (_mode == AiRecommendationMode.local) ..._localFields,
          if (_mode == AiRecommendationMode.vps) ..._vpsFields,
          const SizedBox(height: 16),
          DropdownButtonFormField<int>(
            initialValue: _dailyHour,
            decoration: const InputDecoration(
              labelText: '每日补跑时间',
              border: OutlineInputBorder(),
            ),
            items: List.generate(
              24,
              (hour) => DropdownMenuItem(
                value: hour,
                child: Text('${hour.toString().padLeft(2, '0')}:00 后'),
              ),
            ),
            onChanged: (value) => _dailyHour = value!,
          ),
          const SizedBox(height: 20),
          FilledButton.icon(
            onPressed: _running ? null : _runNow,
            icon: _running
                ? const SizedBox.square(
                    dimension: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.play_arrow),
            label: const Text('保存并立即试跑'),
          ),
          const SizedBox(height: 8),
          OutlinedButton(onPressed: _save, child: const Text('仅保存')),
          const SizedBox(height: 16),
          const Text(
            '本机版会把候选标题、UP、统计数据和你的偏好发送给所填 API 服务商；'
            '只依据这些元数据评分，不会假装读过视频内容。'
            '字幕下载、ASR 和长文本总结更适合放到 VPS。',
            style: TextStyle(color: Colors.grey),
          ),
        ],
      ),
    ),
  );

  List<Widget> get _localFields => [
    DropdownButtonFormField<AiApiFormat>(
      initialValue: _apiFormat,
      decoration: const InputDecoration(
        labelText: 'API 协议',
        border: OutlineInputBorder(),
      ),
      items: const [
        DropdownMenuItem(
          value: AiApiFormat.openAi,
          child: Text('OpenAI-compatible'),
        ),
        DropdownMenuItem(
          value: AiApiFormat.anthropic,
          child: Text('Anthropic-compatible'),
        ),
      ],
      onChanged: (value) => _apiFormat = value!,
    ),
    const SizedBox(height: 12),
    TextFormField(
      controller: _endpointController,
      keyboardType: TextInputType.url,
      decoration: const InputDecoration(
        labelText: 'OpenAI-compatible API 地址',
        hintText: 'https://api.openai.com/v1',
        border: OutlineInputBorder(),
      ),
      validator: _urlValidator,
    ),
    const SizedBox(height: 12),
    TextFormField(
      controller: _apiKeyController,
      obscureText: _obscureApiKey,
      autocorrect: false,
      enableSuggestions: false,
      decoration: InputDecoration(
        labelText: 'API Key（系统安全存储）',
        border: const OutlineInputBorder(),
        suffixIcon: IconButton(
          tooltip: _obscureApiKey ? '显示' : '隐藏',
          onPressed: () => setState(() => _obscureApiKey = !_obscureApiKey),
          icon: Icon(
            _obscureApiKey
                ? Icons.visibility_outlined
                : Icons.visibility_off_outlined,
          ),
        ),
      ),
      validator: (value) =>
          value?.trim().isEmpty == true ? '请填写 API Key' : null,
    ),
    const SizedBox(height: 12),
    TextFormField(
      controller: _modelController,
      decoration: const InputDecoration(
        labelText: '模型名称',
        hintText: '填写服务商支持的模型 ID',
        border: OutlineInputBorder(),
      ),
      validator: (value) => value?.trim().isEmpty == true ? '请填写模型名称' : null,
    ),
    const SizedBox(height: 12),
    TextFormField(
      controller: _preferenceController,
      minLines: 4,
      maxLines: 8,
      decoration: const InputDecoration(
        labelText: '我的偏好',
        alignLabelWithHint: true,
        border: OutlineInputBorder(),
      ),
      validator: (value) => value?.trim().isEmpty == true ? '请描述你的偏好' : null,
    ),
    const SizedBox(height: 12),
    Row(
      children: [
        Expanded(
          child: TextFormField(
            controller: _candidateController,
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            decoration: const InputDecoration(
              labelText: '候选数（5-100）',
              border: OutlineInputBorder(),
            ),
            validator: (value) => _intValidator(value, 5, 100),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: TextFormField(
            controller: _resultController,
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            decoration: const InputDecoration(
              labelText: '精选数（1-30）',
              border: OutlineInputBorder(),
            ),
            validator: (value) => _intValidator(value, 1, 30),
          ),
        ),
      ],
    ),
  ];

  List<Widget> get _vpsFields => [
    TextFormField(
      controller: _remoteUrlController,
      keyboardType: TextInputType.url,
      decoration: const InputDecoration(
        labelText: 'VPS feed.json 地址',
        hintText: 'https://example.com/feed.json',
        border: OutlineInputBorder(),
      ),
      validator: _urlValidator,
    ),
    const SizedBox(height: 12),
    OutlinedButton.icon(
      onPressed: _openPreferenceGroups,
      icon: const Icon(Icons.view_list_outlined),
      label: const Text('管理 VPS 偏好组'),
    ),
    const SizedBox(height: 8),
    const Text(
      '可为每个组选择首页推荐流、B 站搜索或混合来源，并分别编辑评分提示词。',
      style: TextStyle(color: Colors.grey),
    ),
  ];

  String? _urlValidator(String? value) {
    final uri = Uri.tryParse(value?.trim() ?? '');
    return uri != null &&
            uri.hasScheme &&
            const {'http', 'https'}.contains(uri.scheme)
        ? null
        : '请输入 http(s) 地址';
  }

  String? _intValidator(String? value, int min, int max) {
    final number = int.tryParse(value ?? '');
    return number != null && number >= min && number <= max
        ? null
        : '范围 $min-$max';
  }

  Future<bool> _save({bool showToast = true}) async {
    if (_formKey.currentState?.validate() != true) return false;
    final candidateCount = int.parse(_candidateController.text);
    final resultCount = int.parse(_resultController.text);
    if (_mode == AiRecommendationMode.local && resultCount > candidateCount) {
      SmartDialog.showToast('精选数不能大于候选数');
      return false;
    }
    await Future.wait([
      GStorage.setting.putAll({
        SettingBoxKey.aiRcmdEnabled: _enabled,
        SettingBoxKey.aiRcmdMode: _mode.name,
        SettingBoxKey.aiRcmdApiFormat: _apiFormat.name,
        SettingBoxKey.aiRcmdEndpoint: _endpointController.text.trim(),
        SettingBoxKey.aiRcmdModel: _modelController.text.trim(),
        SettingBoxKey.aiRcmdPreference: _preferenceController.text.trim(),
        SettingBoxKey.aiRcmdDailyHour: _dailyHour,
        SettingBoxKey.aiRcmdCandidateCount: candidateCount,
        SettingBoxKey.aiRcmdResultCount: resultCount,
        SettingBoxKey.aiRcmdRemoteUrl: _remoteUrlController.text.trim(),
        SettingBoxKey.aiRcmdHomeSource:
            (_replaceHome
                    ? AiRecommendationHomeSource.ai
                    : AiRecommendationHomeSource.bilibili)
                .name,
      }),
      if (_mode == AiRecommendationMode.local)
        AiRecommendationSecretStore.writeApiKey(_apiKeyController.text),
    ]);
    if (showToast) SmartDialog.showToast('已保存');
    return true;
  }

  Future<void> _runNow() async {
    if (!await _save(showToast: false)) return;
    setState(() => _running = true);
    try {
      await AiRecommendationService().refresh();
      SmartDialog.showToast('AI 精选已更新');
      Get.toNamed('/aiRecommendations');
    } catch (error) {
      SmartDialog.showToast(error.toString());
    } finally {
      if (mounted) setState(() => _running = false);
    }
  }

  Future<void> _openPreferenceGroups() async {
    if (!await _save(showToast: false)) return;
    Get.toNamed('/aiPreferenceGroups');
  }
}
