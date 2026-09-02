/// 全文偏移区间（贯穿阅读器、Agent、存储的统一坐标系）。
/// 允许越界值，使用方负责 clamp（见 DocumentController.textAt）。
class CharRange {
  const CharRange(this.start, this.end);

  final int start;
  final int end;

  int get length => end - start;

  bool contains(int offset) => offset >= start && offset < end;

  bool overlaps(CharRange other) => start < other.end && other.start < end;

  @override
  bool operator ==(Object other) =>
      other is CharRange && other.start == start && other.end == end;

  @override
  int get hashCode => Object.hash(start, end);

  @override
  String toString() => 'CharRange($start, $end)';
}

/// 富文本段内片段（轻量结构，UI 层负责转 TextSpan）。
class RichSegment {
  const RichSegment.text(this.text) : style = SegmentStyle.normal;
  const RichSegment.styled(this.text, this.style);

  final String text;
  final SegmentStyle style;

  RichSegment get bold => RichSegment.styled(text, SegmentStyle.bold);
  RichSegment get code => RichSegment.styled(text, SegmentStyle.code);
  RichSegment get quote => RichSegment.styled(text, SegmentStyle.quote);

  @override
  bool operator ==(Object other) =>
      other is RichSegment && other.text == text && other.style == style;

  @override
  int get hashCode => Object.hash(text, style);
}

enum SegmentStyle { normal, bold, heading1, heading2, heading3, code, quote }

enum ParagraphType { text, heading, codeBlock, listItem, quote }

enum DocFormat { txt, md, json, docx, epub }

enum AnnotationKind { highlight, note, agentRewrite }
