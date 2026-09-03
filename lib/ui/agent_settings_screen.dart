import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../agent/agent_settings.dart';
import '../agent/llm_client.dart';
import '../l10n/app_localizations.dart';
import '../state/app_state.dart';

/// LLM 连接设置：baseURL / API Key / 模型名 全部手填（无预设），
/// 提供"测试连接"一键验证连通性（含 Key 有效性）。
class AgentSettingsScreen extends ConsumerStatefulWidget {
  const AgentSettingsScreen({super.key});

  @override
  ConsumerState<AgentSettingsScreen> createState() => _AgentSettingsScreenState();
}

class _AgentSettingsScreenState extends ConsumerState<AgentSettingsScreen> {
  final _baseUrl = TextEditingController();
  final _apiKey = TextEditingController();
  final _model = TextEditingController();
  bool _loaded = false;
  bool _testing = false;
  ({bool ok, String message, int? ms})? _testResult;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final s = await AgentSettings.instance.read();
    if (mounted) {
      setState(() {
        _baseUrl.text = s.baseUrl;
        _apiKey.text = s.apiKey;
        _model.text = s.model;
        _loaded = true;
      });
    }
  }

  Future<void> _save() async {
    final s = AppLocalizations.of(context)!;
    await AgentSettings.instance.save(
      baseUrl: _baseUrl.text.trim(),
      apiKey: _apiKey.text.trim(),
      model: _model.text.trim(),
    );
    if (mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(s.confirm)));
      Navigator.pop(context);
    }
  }

  Future<void> _testConnection() async {
    final baseUrl = _baseUrl.text.trim();
    final apiKey = _apiKey.text.trim();
    final model = _model.text.trim();
    if (baseUrl.isEmpty || model.isEmpty) {
      setState(() => _testResult =
          (ok: false, message: '请先填写 Base URL 与模型名', ms: null));
      return;
    }
    setState(() {
      _testing = true;
      _testResult = null;
    });
    final sw = Stopwatch()..start();
    try {
      final client =
          LlmClient(baseUrl: baseUrl, apiKey: apiKey, model: model);
      final resp = await client
          .chat(
            messages: [LlmMessage.user('连通性测试，请只回复：pong')],
            temperature: 0,
          )
          .timeout(LlmClient.defaultRequestTimeout);
      sw.stop();
      setState(() => _testResult = (
            ok: true,
            message: '连通成功，模型回复：${resp.content ?? '(空)'}',
            ms: sw.elapsedMilliseconds
          ));
    } catch (e) {
      sw.stop();
      setState(() => _testResult = (
            ok: false,
            message: '连接失败：$e',
            ms: sw.elapsedMilliseconds
          ));
    } finally {
      if (mounted) setState(() => _testing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = AppLocalizations.of(context)!;
    return Scaffold(
      appBar: AppBar(title: Text('${s.settings} · ${s.agentPanel}')),
      body: !_loaded
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                TextField(
                  controller: _baseUrl,
                  decoration: const InputDecoration(
                    labelText: 'Base URL（自己填写，例如 https://api.deepseek.com/v1）',
                    hintText: 'https://你的服务商地址/v1',
                  ),
                ),
                TextField(
                  controller: _apiKey,
                  obscureText: true,
                  decoration: const InputDecoration(
                    labelText: 'API Key（服务商控制台获取，不做预设）',
                  ),
                ),
                TextField(
                  controller: _model,
                  decoration: const InputDecoration(
                    labelText: '模型名（例如 deepseek-chat / qwen-plus）',
                  ),
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  initialValue: PrefsService.instance.loadTranslationProvider(),
                  decoration: const InputDecoration(
                      labelText: '翻译服务（整页/选块翻译使用）'),
                  items: const [
                    DropdownMenuItem(
                        value: 'llm', child: Text('LLM（需上方配置，质量最高）')),
                    DropdownMenuItem(
                        value: 'mymemory',
                        child: Text('MyMemory（免费，无需注册，5000词/天）')),
                    DropdownMenuItem(
                        value: 'google',
                        child: Text('Google 免费接口（国内可能不通）')),
                  ],
                  onChanged: (v) {
                    if (v != null) {
                      PrefsService.instance.saveTranslationProvider(v);
                      setState(() {});
                    }
                  },
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  initialValue: PrefsService.instance.loadAppLocale(),
                  decoration: InputDecoration(labelText: s.language),
                  items: [
                    DropdownMenuItem(value: '', child: Text(s.followSystem)),
                    const DropdownMenuItem(value: 'en', child: Text('English')),
                    const DropdownMenuItem(value: 'zh', child: Text('简体中文')),
                    const DropdownMenuItem(value: 'zh_TW', child: Text('繁體中文')),
                    const DropdownMenuItem(value: 'ja', child: Text('日本語')),
                  ],
                  onChanged: (v) {
                    PrefsService.instance.saveAppLocale(v ?? '');
                    ref.read(appLocaleProvider.notifier).state = v ?? '';
                    setState(() {});
                  },
                ),
                const SizedBox(height: 12),
                Row(children: [
                  FilledButton.icon(
                    onPressed: _testing ? null : _testConnection,
                    icon: _testing
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child:
                                CircularProgressIndicator(strokeWidth: 2))
                        : const Icon(Icons.network_check),
                    label: const Text('测试连接'),
                  ),
                  const SizedBox(width: 12),
                  FilledButton.tonalIcon(
                    onPressed: _save,
                    icon: const Icon(Icons.save),
                    label: Text(s.confirm),
                  ),
                ]),
                if (_testResult != null) ...[
                  const SizedBox(height: 12),
                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: (_testResult!.ok
                              ? Colors.green
                              : Colors.red)
                          .withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      '${_testResult!.ok ? "✅" : "❌"} ${_testResult!.message}'
                      '${_testResult!.ms != null ? "（${_testResult!.ms}ms）" : ""}',
                      style: TextStyle(
                          fontSize: 13,
                          color: _testResult!.ok
                              ? Colors.green.shade700
                              : Colors.red.shade700),
                    ),
                  ),
                ],
                const SizedBox(height: 12),
                Text(
                  '说明：Base URL / API Key / 模型名均由用户自行填写（不做任何预设），'
                  'Key 保存在系统安全存储中。Agent 对话与整本翻译共用此配置，'
                  '测试连接通过后即可使用。',
                  style: TextStyle(
                      fontSize: 12,
                      color: Theme.of(context).colorScheme.outline),
                ),
              ],
            ),
    );
  }
}
