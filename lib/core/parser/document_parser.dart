import '../model/char_range.dart';
import '../model/document.dart';

/// 文档解析器：原始文本 → Document（含全文偏移量）。
/// 不变式：所有解析器必须保证
///   1. charOffset 精确对应原始文本中的位置；
///   2. 段落按序拼接的 [start, start+length) 覆盖整个原文
///      （即首段 charOffset=0，末段 charOffset+length=raw.length）。
abstract class DocumentParser {
  const DocumentParser();

  DocFormat get format;

  Document parse(String docId, String title, String raw);

  /// 按行切分并携带偏移量（\n 与 \r\n 均可）。
  static List<RawLine> splitLines(String raw) {
    final lines = <RawLine>[];
    var start = 0;
    while (start < raw.length) {
      final nl = raw.indexOf('\n', start);
      if (nl == -1) {
        lines.add(RawLine(start, raw.substring(start)));
        break;
      }
      var end = nl;
      if (end > start && raw.codeUnitAt(end - 1) == 0x0D) {
        end--; // \r\n
      }
      lines.add(RawLine(start, raw.substring(start, end)));
      start = nl + 1;
    }
    return lines;
  }

  /// 从行区间 [lineStart, lineEnd) 构造 Paragraph。
  /// [docLength] 用于末段吸收结尾换行，保证全文覆盖不变式。
  static Paragraph buildParagraph(
    List<RawLine> lines,
    int lineStart,
    int lineEnd, {
    required int docLength,
    required int paragraphIndex,
    required ParagraphType type,
    required List<RichSegment> segments,
  }) {
    final charOffset = lines[lineStart].offset;
    final int nextOffset;
    if (lineEnd < lines.length) {
      nextOffset = lines[lineEnd].offset;
    } else {
      nextOffset = docLength;
    }
    return Paragraph(
      index: paragraphIndex,
      type: type,
      segments: segments,
      charOffset: charOffset,
      length: nextOffset - charOffset,
    );
  }

  /// 将 Section 草稿合并成 Document。
  static Document assembleSections(
      String docId, String title, DocFormat format, List<SectionDraft> drafts) {
    final sections = <Section>[];
    for (final d in drafts) {
      if (d.paragraphs.isEmpty) continue;
      sections.add(Section(
        index: sections.length,
        title: d.title,
        paragraphs: d.paragraphs,
        charOffset: d.paragraphs.first.charOffset,
      ));
    }
    return Document(
        id: docId, title: title, format: format, sections: sections);
  }
}

class RawLine {
  const RawLine(this.offset, this.text);
  final int offset;
  final String text;
}

class SectionDraft {
  const SectionDraft(this.title, this.paragraphs);
  final String title;
  final List<Paragraph> paragraphs;
}
