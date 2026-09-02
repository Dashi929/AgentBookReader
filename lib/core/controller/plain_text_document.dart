import '../model/annotation.dart';
import '../model/char_range.dart';
import '../model/document.dart';
import '../parser/document_parser.dart';
import '../parser/json_parser.dart';
import '../parser/md_parser.dart';
import '../parser/txt_parser.dart';
import 'document_controller.dart';

/// 纯文本文档控制器：持有原文，编辑后重解析。
class PlainTextDocument implements DocumentController {
  PlainTextDocument._(this._raw, this._document, this._parser);

  final DocumentParser _parser;
  String _raw;
  Document _document;

  @override
  Document get document => _document;

  @override
  String get rawText => _raw;

  @override
  int get sectionCount => _document.sections.length;

  @override
  int get charCount => _document.charCount;

  /// 按格式选择解析器并载入。
  static Future<PlainTextDocument> create(
      String docId, String title, DocFormat format, String raw) async {
    final DocumentParser parser;
    switch (format) {
      case DocFormat.md:
        parser = const MdParser();
        break;
      case DocFormat.json:
        parser = const JsonParser();
        break;
      case DocFormat.docx:
      case DocFormat.epub:
      case DocFormat.txt:
        parser = const TxtParser();
        break;
    }
    final doc = parser.parse(docId, title, raw);
    return PlainTextDocument._(raw, doc, parser);
  }

  /// 包装已构建的 Document（如译文版），编辑重解析走 TxtParser。
  factory PlainTextDocument.wrap(Document doc, String raw) =>
      PlainTextDocument._(raw, doc, const TxtParser());

  @override
  Section? sectionAt(int index) => _document.sectionAt(index);

  @override
  String textAt(CharRange range) {
    final start = range.start.clamp(0, _raw.length);
    final end = range.end.clamp(start, _raw.length);
    return _raw.substring(start, end);
  }

  @override
  List<SearchHit> search(String query, {int limit = 50}) {
    if (query.isEmpty) return const [];
    final lower = _raw.toLowerCase();
    final needle = query.toLowerCase();
    final hits = <SearchHit>[];
    var from = 0;
    while (hits.length < limit) {
      final idx = lower.indexOf(needle, from);
      if (idx == -1) break;
      final section = _sectionAtOffset(idx);
      final previewStart = (idx - 20).clamp(0, _raw.length);
      final previewEnd = (idx + needle.length + 40).clamp(0, _raw.length);
      hits.add(SearchHit(
        CharRange(idx, idx + needle.length),
        section?.index ?? -1,
        _raw.substring(previewStart, previewEnd).replaceAll('\n', ' '),
      ));
      from = idx + needle.length;
    }
    return hits;
  }

  Section? _sectionAtOffset(int offset) {
    for (final s in _document.sections) {
      if (offset >= s.charOffset && offset < s.charOffset + s.charCount) {
        return s;
      }
    }
    return _document.sections.isNotEmpty ? _document.sections.last : null;
  }

  @override
  Future<Document> applyEdit(DocTextEdit edit) async {
    final start = edit.range.start.clamp(0, _raw.length);
    final end = edit.range.end.clamp(start, _raw.length);
    _raw = _raw.substring(0, start) + edit.newText + _raw.substring(end);
    _document = _parser.parse(_document.id, _document.title, _raw);
    return _document;
  }
}
