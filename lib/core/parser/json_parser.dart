import 'document_parser.dart';
import '../model/char_range.dart';
import '../model/document.dart';

/// JSON 解析：顶层成员（对象键 / 数组元素）各成一个 Section，
/// 成员原文切片作为 codeBlock 段落。成员间的分隔符（逗号/空白）不计入段落。
class JsonParser extends DocumentParser {
  const JsonParser();

  @override
  DocFormat get format => DocFormat.json;

  @override
  Document parse(String docId, String title, String raw) {
    final spans = _topLevelValueSpans(raw);
    final drafts = <SectionDraft>[];
    var paragraphIndex = 0;

    for (var i = 0; i < spans.length; i++) {
      final s = spans[i];
      final slice = raw.substring(s.start, s.end);
      final key = s.label ?? '[${drafts.length}]';
      drafts.add(SectionDraft(key, [
        Paragraph(
          index: paragraphIndex++,
          type: ParagraphType.codeBlock,
          segments: [RichSegment.styled(slice, SegmentStyle.code)],
          charOffset: s.start,
          length: s.end - s.start,
        )
      ]));
    }

    if (drafts.isEmpty) {
      drafts.add(SectionDraft(title, [
        Paragraph(
          index: 0,
          type: ParagraphType.codeBlock,
          segments: [RichSegment.styled(raw, SegmentStyle.code)],
          charOffset: 0,
          length: raw.length,
        )
      ]));
    }

    return DocumentParser.assembleSections(docId, title, DocFormat.json, drafts);
  }
}

class _Span {
  const _Span(this.start, this.end, this.label);
  final int start;
  final int end;
  final String? label;
}

/// 扫描原文，收集根容器内深度 1 的成员区间。
/// 根为对象：成员从键的 '"' 起、到同级 ',' 或收尾 '}' 止，标签为键名；
/// 根为数组：成员从元素首字符起、到同级 ',' 或收尾 ']' 止，标签为 [i]。
/// 根为原始值或解析失败：返回空（调用方回退整文档单 Section）。
List<_Span> _topLevelValueSpans(String raw) {
  final spans = <_Span>[];
  var depth = 0;
  var inString = false;
  var escaped = false;
  var spanStart = -1;
  var objectRoot = false;
  var arrayIndex = 0;

  void closeMember(int endExclusive) {
    if (spanStart != -1) {
      final label = objectRoot ? _keyOf(raw, spanStart) : '[${arrayIndex++}]';
      spans.add(_Span(spanStart, endExclusive, label));
      spanStart = -1;
    }
  }

  for (var i = 0; i < raw.length; i++) {
    final ch = raw[i];
    if (inString) {
      if (escaped) {
        escaped = false;
      } else if (ch == '\\') {
        escaped = true;
      } else if (ch == '"') {
        inString = false;
      }
      continue;
    }
    switch (ch) {
      case '"':
        inString = true;
        if (depth == 1 && spanStart == -1) spanStart = i;
        break;
      case '{':
      case '[':
        if (depth == 0) {
          objectRoot = ch == '{';
          arrayIndex = 0;
        } else if (depth == 1 && spanStart == -1) {
          spanStart = i;
        }
        depth++;
        break;
      case '}':
      case ']':
        if (depth == 1) {
          closeMember(i + 1); // 根容器收尾括号归入最后成员
        }
        depth--;
        break;
      case ',':
        if (depth == 1) {
          closeMember(i);
        }
        break;
      default:
        if (depth == 1 && spanStart == -1 && ch.trim().isNotEmpty) {
          spanStart = i;
        }
        break;
    }
  }
  if (depth == 0 && spanStart != -1) {
    closeMember(raw.length);
  }
  return spans;
}

String _keyOf(String raw, int memberStart) {
  final m = RegExp(r'"((?:[^"\\]|\\.)*)"\s*:').firstMatch(raw.substring(memberStart));
  if (m == null) return '?';
  final key = m.group(1)!;
  return key.length > 24 ? key.substring(0, 24) : key;
}
