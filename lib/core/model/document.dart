import 'char_range.dart';

/// 文档 = 有序 Section 列表。
class Document {
  const Document({
    required this.id,
    required this.title,
    required this.format,
    required this.sections,
  });

  final String id;
  final String title;
  final DocFormat format;
  final List<Section> sections;

  int get charCount =>
      sections.fold(0, (sum, s) => sum + s.charCount);

  Section? sectionAt(int index) =>
      index >= 0 && index < sections.length ? sections[index] : null;
}

class Section {
  const Section({
    required this.index,
    required this.title,
    required this.paragraphs,
    required this.charOffset,
  });

  /// Section 在文档中的序号。
  final int index;

  /// 标题：md 用标题文本；txt 用首行截断或“第 x 段”。
  final String title;
  final List<Paragraph> paragraphs;

  /// Section 首字符在全文中的偏移。
  final int charOffset;

  int get charCount {
    if (paragraphs.isEmpty) return 0;
    final last = paragraphs.last;
    return last.charOffset + last.length - charOffset;
  }

  /// Section 内所有段落文本拼接（不含 Section 间分隔符）。
  String get plainText => paragraphs.map((p) => p.plainText).join();
}

class Paragraph {
  const Paragraph({
    required this.index,
    required this.type,
    required this.segments,
    required this.charOffset,
    required this.length,
  });

  final int index;
  final ParagraphType type;
  final List<RichSegment> segments;

  /// 段首字符在全文中的偏移。
  final int charOffset;

  /// 含段尾换行的字符数（用于偏移推进）。
  final int length;

  String get plainText =>
      segments.map((s) => s.text).join();
}
