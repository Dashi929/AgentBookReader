import 'package:flutter_test/flutter_test.dart';
import 'package:agent_book_reader/core/model/document.dart';
import 'package:agent_book_reader/core/pagination/paginator.dart';
import 'package:agent_book_reader/core/pagination/page_anchor.dart';
import 'package:agent_book_reader/core/parser/txt_parser.dart';

Document _doc(List<String> paragraphTexts) {
  final raw = paragraphTexts.join('\n\n');
  return const TxtParser().parse('t', 'T', raw);
}

void main() {
  // Ahem 字体：度量确定性。12 段 × 30 字，宽 379/字号可产生多页。
  final paras = List.generate(12, (i) => '第${i + 1}段：${'内容文字' * 8}');

  test('locate：锚点字符落在包含它的 (页, 行) 上', () {
    final doc = _doc(paras);
    final pages = Paginator.paginate(
        doc, const ReaderPageConfig(width: 379, height: 803, fontSize: 18));
    expect(pages.length, greaterThan(1));

    // 取第 2 页首行（跨页段落场景）作为锚点
    final anchor = PageAnchor.charOffsetForPageTop(pages[1], doc);
    expect(anchor, isNotNull);

    final hit = PageAnchor.locate(pages, doc, anchor!)!;
    expect(hit.$1, equals(1));
    expect(hit.$2, equals(0), reason: '锚点取自该页首行，应精确命中第 0 行');
  });

  test('字号变小后：锚点不回跳到文档开头（回归：滑杆漂移 bug）', () {
    final doc = _doc(paras);
    final big = Paginator.paginate(
        doc, const ReaderPageConfig(width: 379, height: 803, fontSize: 24));
    final small = Paginator.paginate(
        doc, const ReaderPageConfig(width: 379, height: 803, fontSize: 14));
    expect(big.length, greaterThan(1));
    expect(small.length, greaterThanOrEqualTo(1));
    expect(small.length, lessThanOrEqualTo(big.length),
        reason: '小字号单页容量更大，页数应不多于大字号');

    // 大字号第 2 页首行 = 跨页段落中间位置
    final anchor = PageAnchor.charOffsetForPageTop(big[1], doc)!;
    final hit = PageAnchor.locate(small, doc, anchor)!;

    // 旧 bug 的症状：锚点落到第 1 页顶部（行 0 附近）。字符级锚点不允许。
    final notAtDocStart = hit.$1 > 0 || hit.$2 > small[0].lines.length * 0.2;
    expect(notAtDocStart, isTrue,
        reason: '锚点(${hit.$1},${hit.$2}) 不应落在第 1 页顶部');

    final target = PageAnchor.targetPage(small, doc, anchor);
    expect(target, inInclusiveRange(0, small.length - 1));
  });

  test('字号变大后：锚点仍映射到包含它的页面附近', () {
    final doc = _doc(paras);
    final small = Paginator.paginate(
        doc, const ReaderPageConfig(width: 379, height: 803, fontSize: 14));
    final big = Paginator.paginate(
        doc, const ReaderPageConfig(width: 379, height: 803, fontSize: 24));

    final anchor = PageAnchor.charOffsetForPageTop(small[1], doc)!;
    final hit = PageAnchor.locate(big, doc, anchor)!;
    expect(hit.$1, inInclusiveRange(0, big.length - 1));
    // 不允许回到文档开头顶部
    final notAtDocStart = hit.$1 > 0 || hit.$2 > big[0].lines.length * 0.2;
    expect(notAtDocStart, isTrue);
  });

  test('targetPage：锚点在页下部时优先下一页（保持阅读接续）', () {
    final doc = _doc(paras);
    final pages = Paginator.paginate(
        doc, const ReaderPageConfig(width: 379, height: 803, fontSize: 18));
    expect(pages.length, greaterThan(1));

    // 构造一个肯定在页面底部的锚点：最后一页的最后一行
    final lastPage = pages.last;
    final lastLine = lastPage.lines.last;
    final para = doc.sections
        .expand((s) => s.paragraphs)
        .firstWhere((p) => p.index == lastLine.paragraphIndex);
    final paraText = para.segments.map((s) => s.text).join();
    final lineText = lastLine.segments.map((s) => s.text).join();
    final anchor = para.charOffset + paraText.indexOf(lineText);

    final hit = PageAnchor.locate(pages, doc, anchor)!;
    final lineCount = pages[hit.$1].lines.length;
    final expected = (lineCount > 1 && hit.$2 / lineCount > 0.6)
        ? (hit.$1 < pages.length - 1 ? hit.$1 + 1 : hit.$1)
        : hit.$1;
    expect(PageAnchor.targetPage(pages, doc, anchor), equals(expected));
  });
}
