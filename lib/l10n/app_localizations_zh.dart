// ignore: unused_import
import 'package:intl/intl.dart' as intl;

import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for Chinese (`zh`).
class AppLocalizationsZh extends AppLocalizations {
  AppLocalizationsZh([String locale = 'zh']) : super(locale);

  @override
  String get appTitle => 'AgentBookReader';

  @override
  String get library => '书架';

  @override
  String get settings => '设置';

  @override
  String get reader => '阅读';

  @override
  String get importFiles => '导入文件';

  @override
  String importFailed(String reason) {
    return '导入失败：$reason';
  }

  @override
  String get agentPanel => '智能助手';

  @override
  String get agentAsk => '向助手提问这本书…';

  @override
  String get agentWorkspaceSelect => '选择要处理的文档（可多选）';

  @override
  String get agentWorkspaceAsk => '让 Agent 处理选中的文档…';

  @override
  String get translate => '翻译';

  @override
  String translateJobRunning(int done, int total) {
    return '翻译中 $done/$total…';
  }

  @override
  String get originalText => '原文';

  @override
  String get translatedText => '译文';

  @override
  String section(int n) {
    return '第$n节';
  }

  @override
  String page(int n) {
    return '第 $n 页';
  }

  @override
  String words(int count) {
    return '$count 字';
  }

  @override
  String get confirm => '确认';

  @override
  String get cancel => '取消';

  @override
  String get llmBaseUrl => '接口地址';

  @override
  String get llmApiKey => 'API Key';

  @override
  String get llmModel => '模型名';

  @override
  String get proposalTitle => '改写提案';

  @override
  String get reject => '拒绝';

  @override
  String get apply => '确认应用';

  @override
  String get editSection => '编辑本节';

  @override
  String unTranslated(String title) {
    return '【本节尚未翻译】$title';
  }

  @override
  String get annotations => '批注';

  @override
  String get export => '导出';

  @override
  String get chapters => '章节';

  @override
  String get writeBack => '写入原文件(.bak)';

  @override
  String get originalFileUpdated => '原文件已备份并更新';
}
