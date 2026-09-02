import '../model/annotation.dart';
import '../model/char_range.dart';
import '../model/document.dart';

/// 文档抽象层：Agent 与 UI 只依赖此接口。
/// 二期新增 EPUB/PDF 时各提供实现，不改调用方。
/// 构造由各实现的静态工厂承担（如 PlainTextDocument.create）。
abstract class DocumentController {
  Document get document;

  /// 当前文档全文（编辑后的最新状态）。
  String get rawText;

  /// 全文字数（便捷统计）。
  int get charCount;

  Section? sectionAt(int index);

  /// 读取区间原文（Agent 读）。
  String textAt(CharRange range);

  /// 关键词搜索（大小写不敏感），返回命中区间与预览。
  List<SearchHit> search(String query, {int limit = 50});

  /// 应用文本编辑并重解析（Agent 写路径，UI 确认后调用）。
  Future<Document> applyEdit(DocTextEdit edit);

  int get sectionCount;
}
