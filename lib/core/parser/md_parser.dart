import 'document_parser.dart';
import '../model/char_range.dart';
import '../model/document.dart';

/// Markdown 解析：标题切 Section；``` 代码块、列表、引用识别段落类型；
/// 行内 **加粗** 与 `代码` 解析为富文本片段。
/// 语义：charOffset/length 精确映射原文切片；plainText 为渲染后文本
/// （行内标记已剥离），二者不一致是预期行为（txt/json 保持一致）。
class MdParser extends DocumentParser {
  const MdParser();

  @override
  DocFormat get format => DocFormat.md;

  @override
  Document parse(String docId, String title, String raw) {
    final lines = DocumentParser.splitLines(raw);
    final drafts = <SectionDraft>[];
    var currentTitle = title;
    var sectionOpened = false;
    var currentParagraphs = <Paragraph>[];
    var paragraphIndex = 0;

    void closeSection() {
      if (sectionOpened) {
        drafts.add(SectionDraft(currentTitle, currentParagraphs));
        currentParagraphs = <Paragraph>[];
        sectionOpened = false;
      }
    }

    var i = 0;
    var paragraphStart = -1;
    void flushParagraph(int endLine) {
      if (paragraphStart == -1) return;
      final charStart = lines[paragraphStart].offset;
      final charEnd = endLine < lines.length ? lines[endLine].offset : raw.length;
      final slice = raw.substring(charStart, charEnd);
      final first = lines[paragraphStart].text.trimLeft();
      final (type, style) = _classify(first);
      currentParagraphs.add(Paragraph(
        index: paragraphIndex++,
        type: type,
        segments: MdParser.parseInline(slice, base: style),
        charOffset: charStart,
        length: charEnd - charStart,
      ));
      paragraphStart = -1;
    }

    while (i < lines.length) {
      final line = lines[i];
      final trimmed = line.text.trimLeft();

      // 代码围栏
      if (trimmed.startsWith('```')) {
        flushParagraph(i);
        sectionOpened = true;
        final fenceStart = i;
        i++;
        while (i < lines.length && !lines[i].text.trimLeft().startsWith('```')) {
          i++;
        }
        final endLine = (i < lines.length) ? i + 1 : i;
        final charStart = lines[fenceStart].offset;
        final charEnd = endLine < lines.length ? lines[endLine].offset : raw.length;
        currentParagraphs.add(Paragraph(
          index: paragraphIndex++,
          type: ParagraphType.codeBlock,
          segments: [RichSegment.styled(raw.substring(charStart, charEnd), SegmentStyle.code)],
          charOffset: charStart,
          length: charEnd - charStart,
        ));
        i = endLine;
        continue;
      }

      // ATX 标题 → 切 Section
      final heading = RegExp(r'^(#{1,6})\s+(.*)$').firstMatch(trimmed);
      if (heading != null) {
        flushParagraph(i);
        closeSection();
        final level = heading.group(1)!.length;
        final style = level == 1
            ? SegmentStyle.heading1
            : level == 2
                ? SegmentStyle.heading2
                : SegmentStyle.heading3;
        final charStart = line.offset;
        final charEnd = (i + 1) < lines.length ? lines[i + 1].offset : raw.length;
        currentTitle = heading.group(2)!.trim();
        sectionOpened = true;
        currentParagraphs.add(Paragraph(
          index: paragraphIndex++,
          type: ParagraphType.heading,
          segments: [RichSegment.styled(raw.substring(charStart, charEnd), style)],
          charOffset: charStart,
          length: charEnd - charStart,
        ));
        i++;
        continue;
      }

      if (trimmed.isEmpty) {
        flushParagraph(i);
        i++;
        continue;
      }

      if (paragraphStart == -1) {
        paragraphStart = i;
        sectionOpened = true;
      }
      i++;
    }
    flushParagraph(lines.length);
    closeSection();

    if (drafts.isEmpty) {
      drafts.add(SectionDraft(title, const []));
    }
    return DocumentParser.assembleSections(docId, title, DocFormat.md, drafts);
  }

  (ParagraphType, SegmentStyle) _classify(String first) {
    if (first.startsWith(RegExp(r'[-*+]\s')) || first.startsWith(RegExp(r'\d+[.)]\s'))) {
      return (ParagraphType.listItem, SegmentStyle.normal);
    }
    if (first.startsWith('>')) return (ParagraphType.quote, SegmentStyle.quote);
    return (ParagraphType.text, SegmentStyle.normal);
  }

  /// 行内解析：**粗体** 与 `行内代码`。
  static List<RichSegment> parseInline(String text, {SegmentStyle base = SegmentStyle.normal}) {
    final segments = <RichSegment>[];
    final buffer = StringBuffer();
    var i = 0;
    var bold = false;
    var code = false;

    void flush() {
      if (buffer.isEmpty) return;
      final t = buffer.toString();
      if (code) {
        segments.add(RichSegment.styled(t, SegmentStyle.code));
      } else if (bold) {
        segments.add(RichSegment.styled(t, SegmentStyle.bold));
      } else {
        segments.add(RichSegment.styled(t, base));
      }
      buffer.clear();
    }

    while (i < text.length) {
      if (!code && i + 1 < text.length && text.startsWith('**', i)) {
        flush();
        bold = !bold;
        i += 2;
        continue;
      }
      if (text[i] == '`') {
        flush();
        code = !code;
        i += 1;
        continue;
      }
      buffer.writeCharCode(text.codeUnitAt(i));
      i++;
    }
    flush();
    if (segments.isEmpty) segments.add(RichSegment.styled(text, base));
    return segments;
  }
}
