import 'package:flutter_test/flutter_test.dart';
import 'package:agent_book_reader/core/parser/md_parser.dart';
import 'package:agent_book_reader/core/model/char_range.dart';

void main() {
  const parser = MdParser();

  test('标题切 Section', () {
    final raw = '# 第一章\n内容甲\n\n## 小节\n内容乙\n# 第二章\n内容丙';
    final doc = parser.parse('d1', '书', raw);

    expect(doc.sections.length, 3);
    expect(doc.sections[0].title, '第一章');
    expect(doc.sections[1].title, '小节');
    expect(doc.sections[2].title, '第二章');
    expect(doc.sections[0].paragraphs.first.type, ParagraphType.heading);
  });

  test('粗体与行内代码片段', () {
    final raw = '普通**加粗**文字`代码`尾';
    final doc = parser.parse('d2', '书', raw);
    final segs = doc.sections.first.paragraphs.first.segments;

    // 标记被剥离，渲染文本为纯内容；偏移量仍映射原文
    expect(segs.map((s) => s.text).join(), '普通加粗文字代码尾');
    expect(segs.where((s) => s.style == SegmentStyle.bold).map((s) => s.text),
        contains('加粗'));
    expect(segs.where((s) => s.style == SegmentStyle.code).map((s) => s.text),
        contains('代码'));
  });

  test('代码围栏识别', () {
    final raw = '前置\n\n```dart\nvoid main() {}\n```\n\n后置';
    final doc = parser.parse('d3', '书', raw);
    final all = doc.sections.expand((s) => s.paragraphs).toList();
    final codeBlocks = all.where((p) => p.type == ParagraphType.codeBlock).toList();
    expect(codeBlocks.length, 1);
    expect(codeBlocks.first.plainText, contains('void main()'));
  });

  test('偏移量覆盖不变式（含代码块与空行）', () {
    final raw = '# T\n甲**粗**乙\n\n```js\nvar a;\n```\n\n> 引用\n- 列表\n\n尾段';
    final doc = parser.parse('d4', '书', raw);
    final all = doc.sections.expand((s) => s.paragraphs).toList()
      ..sort((a, b) => a.charOffset.compareTo(b.charOffset));

    // md 段落 plainText 为渲染文本（标记剥离），但偏移量必须落在原文内且不越界
    for (final p in all) {
      expect(p.charOffset, inInclusiveRange(0, raw.length),
          reason: '段落 ${p.index} 起点越界');
      expect(p.charOffset + p.length, lessThanOrEqualTo(raw.length),
          reason: '段落 ${p.index} 越过文末');
    }
    // 段落间偏移单调递增且不重叠
    for (var i = 1; i < all.length; i++) {
      expect(all[i].charOffset,
          greaterThanOrEqualTo(all[i - 1].charOffset + all[i - 1].length));
    }
    // 无标题前导内容也应有 Section
    expect(doc.sections, isNotEmpty);
  });

  test('无标题文档单 Section', () {
    final raw = '只有正文\n第二行';
    final doc = parser.parse('d5', '默认标题', raw);
    expect(doc.sections.length, 1);
    expect(doc.sections.first.title, '默认标题');
  });
}
