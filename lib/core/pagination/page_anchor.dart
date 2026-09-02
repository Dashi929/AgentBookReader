import '../model/document.dart';
import 'paginator.dart';

/// 页面锚定：字号变更/编辑重排后，把阅读位置映射回新分页。
///
/// 用"当前页首行在全文中的字符偏移"做锚点。段落级锚点在跨页段落
/// 场景会回退到段首页（视觉上丢失位置）；字符级锚点可精确保留位置，
/// 且锚点位于目标页下部时优先显示下一页，保持阅读接续感。
class PageAnchor {
  PageAnchor._();

  /// 锚点 = [page] 首行文本在其段落内的偏移 + 段首全局偏移。
  /// 页面为空或找不到段落时返回 null。
  static int? charOffsetForPageTop(ReaderPage page, Document doc) {
    if (page.lines.isEmpty) return null;
    final line = page.lines.first;
    final para = _paragraphByIndex(doc, line.paragraphIndex);
    if (para == null) return null;
    final paraText = para.segments.map((s) => s.text).join();
    final lineText = line.segments.map((s) => s.text).join();
    final inPara = paraText.indexOf(lineText);
    return para.charOffset + (inPara == -1 ? 0 : inPara);
  }

  /// 找到包含 [charOffset] 的 (页码, 页内行号)；找不到返回 null。
  static (int, int)? locate(
      List<ReaderPage> pages, Document doc, int charOffset) {
    int? lastParaIndex;
    var offsetInPara = 0;
    for (var i = 0; i < pages.length; i++) {
      for (var li = 0; li < pages[i].lines.length; li++) {
        final line = pages[i].lines[li];
        if (line.paragraphIndex != lastParaIndex) {
          lastParaIndex = line.paragraphIndex;
          offsetInPara = 0;
        }
        final para = _paragraphByIndex(doc, line.paragraphIndex);
        if (para == null) continue;
        final len = line.segments.fold<int>(0, (n, s) => n + s.text.length);
        final absStart = para.charOffset + offsetInPara;
        if (charOffset >= absStart && charOffset < absStart + len) {
          return (i, li);
        }
        offsetInPara += len;
      }
    }
    return null;
  }

  /// 锚点落位页码：锚点行位于目标页下部（>60%）时显示下一页。
  /// 找不到锚点返回 -1。
  static int targetPage(
      List<ReaderPage> pages, Document doc, int charOffset) {
    final hit = locate(pages, doc, charOffset);
    if (hit == null) return -1;
    var target = hit.$1;
    final lineCount = pages[target].lines.length;
    if (lineCount > 1 && hit.$2 / lineCount > 0.6) {
      if (target < pages.length - 1) target++;
    }
    return target;
  }

  static Paragraph? _paragraphByIndex(Document doc, int paragraphIndex) {
    for (final s in doc.sections) {
      for (final p in s.paragraphs) {
        if (p.index == paragraphIndex) return p;
      }
    }
    return null;
  }
}
