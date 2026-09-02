import 'package:flutter/painting.dart';

import '../model/char_range.dart';
import '../model/document.dart';

/// 分页配置：内容区宽高（去边距后）、字号、行高倍数、段间距。
class ReaderPageConfig {
  const ReaderPageConfig({
    required this.width,
    required this.height,
    this.fontSize = 18,
    this.lineHeight = 1.6,
    this.paragraphSpacing = 10,
    this.imageLineHeight,
  });

  final double width;
  final double height;
  final double fontSize;
  final double lineHeight;
  final double paragraphSpacing;

  /// 图片段落解析器：段落文本匹配图片占位符时返回该行显示高度（含留白），
  /// 返回 null 按普通文本排版。用于 docx/epub 内嵌图片的整行渲染。
  final double? Function(String paragraphText)? imageLineHeight;
}

/// 页内一行：段落序号 + 该行的富文本切片。
class PageLine {
  const PageLine(this.paragraphIndex, this.segments, this.height);
  final int paragraphIndex;
  final List<RichSegment> segments;
  final double height;
}

class ReaderPage {
  const ReaderPage(this.lines);
  final List<PageLine> lines;
}

/// 行级分页器：TextPainter 逐段测量 → 行为单位贪心装页。
/// 段落可跨页；行内样式随段切片保留。
class Paginator {
  static List<ReaderPage> paginate(Document doc, ReaderPageConfig cfg) {
    final pages = <ReaderPage>[];
    var current = <PageLine>[];
    var used = 0.0;
    var lastParagraph = -1;

    void closePage() {
      if (current.isNotEmpty) pages.add(ReaderPage(List.of(current)));
      current = <PageLine>[];
      used = 0;
      lastParagraph = -1;
    }

    for (final section in doc.sections) {
      for (final p in section.paragraphs) {
        final text = p.plainText;
        if (text.trim().isEmpty) continue;
        final imageHeight = cfg.imageLineHeight?.call(text);
        if (imageHeight != null) {
          // 图片段：整段一行，高度由解析器给定（保持 CharRange/偏移不变式，
          // 行 segments 仍为占位符文本）。
          if (current.isNotEmpty && p.index != lastParagraph) {
            used += cfg.paragraphSpacing;
          }
          if (used + imageHeight > cfg.height && current.isNotEmpty) {
            closePage();
          }
          current.add(PageLine(p.index, p.segments, imageHeight));
          used += imageHeight;
          lastParagraph = p.index;
          continue;
        }
        final spans = TextSpan(
          children: p.segments
              .map((s) => TextSpan(
                  text: s.text,
                  style: _styleOf(s.style, cfg.fontSize, cfg.lineHeight)))
              .toList(),
        );
        final tp = TextPainter(
          text: spans,
          textDirection: TextDirection.ltr,
        )..layout(maxWidth: cfg.width);

        final metrics = tp.computeLineMetrics();
        // 每个视觉行的起点：x=0 处的位置（LTR 左对齐）；
        // 行尾 = 下一行起点（含本行换行符）。禁止用"下一行几何+右边缘"取行尾——
        // 那会取到下一行的行尾，导致每个切片跨两行、渲染时被 maxLines:1 裁掉（丢内容）。
        final starts = <int>[];
        for (var li = 0; li < metrics.length; li++) {
          final m = metrics[li];
          starts.add(li == 0
              ? 0
              : tp.getPositionForOffset(Offset(0, m.baseline - m.height * 0.5)).offset);
        }
        for (var li = 0; li < metrics.length; li++) {
          final m = metrics[li];
          final lineEnd = li + 1 < metrics.length ? starts[li + 1] : text.length;

          // 段间距：新段落的首页行计入
          if (current.isNotEmpty && p.index != lastParagraph) {
            used += cfg.paragraphSpacing;
          }
          if (used + m.height > cfg.height && current.isNotEmpty) {
            closePage();
          }
          current.add(PageLine(
              p.index, _sliceSegments(p.segments, starts[li], lineEnd), m.height));
          used += m.height;
          lastParagraph = p.index;
        }
        tp.dispose();
      }
    }
    closePage();
    return pages;
  }

  static TextStyle _styleOf(SegmentStyle style, double fontSize, double lineHeight) {
    final base = TextStyle(fontSize: fontSize, height: lineHeight);
    switch (style) {
      case SegmentStyle.bold:
        return base.copyWith(fontWeight: FontWeight.bold);
      case SegmentStyle.heading1:
        return base.copyWith(fontSize: fontSize * 1.5, fontWeight: FontWeight.bold);
      case SegmentStyle.heading2:
        return base.copyWith(fontSize: fontSize * 1.3, fontWeight: FontWeight.w600);
      case SegmentStyle.heading3:
        return base.copyWith(fontSize: fontSize * 1.15, fontWeight: FontWeight.w600);
      case SegmentStyle.code:
        return base.copyWith(fontFamily: 'monospace');
      case SegmentStyle.quote:
        return base.copyWith(fontStyle: FontStyle.italic, color: const Color(0xFF666666));
      case SegmentStyle.normal:
        return base;
    }
  }

  /// 按渲染文本偏移切片段（保留样式）。
  static List<RichSegment> _sliceSegments(
      List<RichSegment> segments, int start, int end) {
    final out = <RichSegment>[];
    var cursor = 0;
    for (final s in segments) {
      final segStart = cursor;
      final segEnd = cursor + s.text.length;
      cursor = segEnd;
      if (segEnd <= start) continue;
      if (segStart >= end) break;
      final from = (start - segStart).clamp(0, s.text.length);
      final to = (end - segStart).clamp(0, s.text.length);
      if (to > from) out.add(RichSegment.styled(s.text.substring(from, to), s.style));
    }
    return out;
  }
}
