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
  String get translateTo => '翻译到…';

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

  @override
  String get bookDetail => '图书详情';

  @override
  String get author => '作者';

  @override
  String get synopsis => '简介';

  @override
  String get preview => '预览';

  @override
  String get startReading => '开始阅读';

  @override
  String get aiComplete => 'AI 补全信息';

  @override
  String get unknownAuthor => '未知作者';

  @override
  String get aiCompleteDone => '信息已补全';

  @override
  String get noSynopsis => '暂无简介，可点击\"AI 补全信息\"生成';

  @override
  String continueReading(String page) {
    return '继续阅读：$page';
  }

  @override
  String get language => '语言';

  @override
  String get followSystem => '跟随系统';

  @override
  String get editTextLayer => '编辑文字层';

  @override
  String get selectText => '选择文字';

  @override
  String get continuousMode => '连续阅读';

  @override
  String get singlePageMode => '单页模式';

  @override
  String get saveAs => '另存为';

  @override
  String get overwrite => '覆盖';

  @override
  String get discardChanges => '放弃修改';

  @override
  String get continueEditing => '继续编辑';

  @override
  String get unsavedTitle => '有未保存的修改';

  @override
  String get exitSaveOffice =>
      '该格式的编辑作用于文字层（Agent/翻译/详情使用）；\n覆盖 = 存入应用内缓存并长期生效；另存 = 导出为 Markdown 文件。';

  @override
  String get exitSaveText => '覆盖 = 写回原文件（自动备份 .bak）；另存 = 导出为新文件。';

  @override
  String get pageTextTitle => '本页文字（长按可选择）';

  @override
  String get copySelected => '复制所选';

  @override
  String get translateSelected => '翻译所选';

  @override
  String get noPageText => '（本页没有可选择的文字）';

  @override
  String get editCacheSaved => '已保存到编辑缓存，退出时可选另存 / 覆盖';

  @override
  String get readingProgress => '阅读进度';

  @override
  String get readingSettings => '阅读设置';

  @override
  String get search => '搜索';

  @override
  String get brightness => '亮度';

  @override
  String get lineSpacing => '行距';

  @override
  String get paraSpacing => '段距';

  @override
  String get pageMargin => '页边距';

  @override
  String get jumpToPage => '跳页';

  @override
  String get keepAwake => '屏幕常亮';

  @override
  String get immersiveMode => '沉浸模式（隐藏状态栏）';

  @override
  String get searchHint => '全书搜索关键词…';

  @override
  String get noResults => '无结果';

  @override
  String get searchIn => '搜索结果';

  @override
  String get theme => '主题';

  @override
  String get fontSize => '字号';
}

/// The translations for Chinese, as used in Taiwan (`zh_TW`).
class AppLocalizationsZhTw extends AppLocalizationsZh {
  AppLocalizationsZhTw() : super('zh_TW');

  @override
  String get appTitle => 'AgentBookReader';

  @override
  String get library => '書架';

  @override
  String get settings => '設定';

  @override
  String get reader => '閱讀';

  @override
  String get importFiles => '匯入文件';

  @override
  String importFailed(String reason) {
    return '匯入失敗：$reason';
  }

  @override
  String get agentPanel => '智慧助理';

  @override
  String get agentAsk => '向助理提問這本書…';

  @override
  String get agentWorkspaceSelect => '選擇要處理的文檔（可多選）';

  @override
  String get agentWorkspaceAsk => '讓 Agent 處理選中的文檔…';

  @override
  String get translate => '翻譯';

  @override
  String get translateTo => '翻譯到…';

  @override
  String translateJobRunning(int done, int total) {
    return '翻譯中 $done/$total…';
  }

  @override
  String get originalText => '原文';

  @override
  String get translatedText => '譯文';

  @override
  String section(int n) {
    return '第$n節';
  }

  @override
  String page(int n) {
    return '第 $n 頁';
  }

  @override
  String words(int count) {
    return '$count 字';
  }

  @override
  String get confirm => '確認';

  @override
  String get cancel => '取消';

  @override
  String get llmBaseUrl => '接口地址';

  @override
  String get llmApiKey => 'API Key';

  @override
  String get llmModel => '模型名';

  @override
  String get proposalTitle => '改寫提案';

  @override
  String get reject => '拒絕';

  @override
  String get apply => '確認應用';

  @override
  String get editSection => '編輯本節';

  @override
  String unTranslated(String title) {
    return '【本節尚未翻譯】$title';
  }

  @override
  String get annotations => '批註';

  @override
  String get export => '匯出';

  @override
  String get chapters => '章節';

  @override
  String get writeBack => '寫入原文件(.bak)';

  @override
  String get originalFileUpdated => '原文件已備份並更新';

  @override
  String continueReading(String page) {
    return '繼續閱讀：$page';
  }

  @override
  String get language => '語言';

  @override
  String get followSystem => '跟隨系統';

  @override
  String get editTextLayer => '編輯文字層';

  @override
  String get selectText => '選擇文字';

  @override
  String get continuousMode => '連續閱讀';

  @override
  String get singlePageMode => '單頁模式';

  @override
  String get saveAs => '另存為';

  @override
  String get overwrite => '覆蓋';

  @override
  String get discardChanges => '放棄修改';

  @override
  String get continueEditing => '繼續編輯';

  @override
  String get unsavedTitle => '有未儲存的修改';

  @override
  String get exitSaveOffice =>
      '該格式的編輯作用於文字層（Agent/翻譯/詳情使用）；\n覆蓋 = 存入應用內快取並長期生效；另存 = 匯出為 Markdown 檔案。';

  @override
  String get exitSaveText => '覆蓋 = 寫回原檔案（自動備份 .bak）；另存 = 匯出為新檔案。';

  @override
  String get pageTextTitle => '本頁文字（長按可選擇）';

  @override
  String get copySelected => '複製所選';

  @override
  String get translateSelected => '翻譯所選';

  @override
  String get noPageText => '（本頁沒有可選擇的文字）';

  @override
  String get editCacheSaved => '已保存到編輯快取，退出時可選另存 / 覆蓋';

  @override
  String get readingProgress => '閱讀進度';

  @override
  String get readingSettings => '閱讀設定';

  @override
  String get search => '搜尋';

  @override
  String get brightness => '亮度';

  @override
  String get lineSpacing => '行距';

  @override
  String get paraSpacing => '段距';

  @override
  String get pageMargin => '頁邊距';

  @override
  String get jumpToPage => '跳頁';

  @override
  String get keepAwake => '螢幕常亮';

  @override
  String get immersiveMode => '沉浸模式（隱藏狀態列）';

  @override
  String get searchHint => '全書搜尋關鍵字…';

  @override
  String get noResults => '無結果';

  @override
  String get searchIn => '搜尋結果';

  @override
  String get theme => '主題';

  @override
  String get fontSize => '字號';
}
