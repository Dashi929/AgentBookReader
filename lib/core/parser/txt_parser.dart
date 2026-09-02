import 'document_parser.dart';
import '../model/char_range.dart';
import '../model/document.dart';

/// txt 解析：空行分段；超过 [maxGroupLines] 行的段硬切；每 [sectionSize] 段一个 Section。
class TxtParser extends DocumentParser {
  const TxtParser({this.sectionSize = 50, this.maxGroupLines = 200});

  final int sectionSize;
  final int maxGroupLines;

  @override
  DocFormat get format => DocFormat.txt;

  @override
  Document parse(String docId, String title, String raw) {
    final lines = DocumentParser.splitLines(raw);

    // 1) 连续非空行 → 行区间 [start, end)
    final ranges = <List<int>>[];
    var start = -1;
    for (var i = 0; i < lines.length; i++) {
      final blank = lines[i].text.trim().isEmpty;
      if (!blank && start == -1) start = i;
      if (blank && start != -1) {
        ranges.add([start, i]);
        start = -1;
      }
    }
    if (start != -1) ranges.add([start, lines.length]);

    // 2) 超长区间硬切
    final capped = <List<int>>[];
    for (final r in ranges) {
      for (var s = r[0]; s < r[1]; s += maxGroupLines) {
        capped.add([s, (s + maxGroupLines > r[1]) ? r[1] : s + maxGroupLines]);
      }
    }

    // 3) 行区间 → Paragraph（片段文本 == 原文切片，含段尾空行）
    final paragraphs = <Paragraph>[];
    if (capped.isEmpty) {
      paragraphs.add(Paragraph(
        index: 0,
        type: ParagraphType.text,
        segments: const [RichSegment.text('')],
        charOffset: 0,
        length: raw.length,
      ));
    } else {
      for (var i = 0; i < capped.length; i++) {
        final charStart = lines[capped[i][0]].offset;
        final charEnd =
            capped[i][1] < lines.length ? lines[capped[i][1]].offset : raw.length;
        paragraphs.add(Paragraph(
          index: i,
          type: ParagraphType.text,
          segments: [RichSegment.text(raw.substring(charStart, charEnd))],
          charOffset: charStart,
          length: charEnd - charStart,
        ));
      }
    }

    // 4) 每 sectionSize 段 → Section
    final drafts = <SectionDraft>[];
    for (var i = 0; i < paragraphs.length; i += sectionSize) {
      final end = (i + sectionSize > paragraphs.length)
          ? paragraphs.length
          : i + sectionSize;
      final chunk = paragraphs.sublist(i, end);
      final head = chunk.first.plainText.trim();
      final sectionTitle = head.isEmpty
          ? 'Section ${drafts.length + 1}'
          : (head.length > 24 ? head.substring(0, 24) : head);
      drafts.add(SectionDraft(sectionTitle, chunk));
    }

    return DocumentParser.assembleSections(docId, title, DocFormat.txt, drafts);
  }
}
