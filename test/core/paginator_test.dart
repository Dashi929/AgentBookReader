import 'package:flutter_test/flutter_test.dart';
import 'package:agent_book_reader/core/model/char_range.dart';
import 'package:agent_book_reader/core/model/document.dart';
import 'package:agent_book_reader/core/pagination/paginator.dart';
import 'package:agent_book_reader/core/parser/md_parser.dart';
import 'package:agent_book_reader/core/parser/txt_parser.dart';

Document _txtDoc(List<String> paragraphTexts) {
  final raw = paragraphTexts.join('\n\n');
  return const TxtParser().parse('t', 'T', raw);
}

void main() {
  // 测试字体 Ahem：每个字形宽=fontSize、行高=fontSize*height（确定性度量）
  test('行级分页：段落跨页拆分', () {
    final doc = _txtDoc(['0123456789' * 3, 'abcdefghij' * 3, 'klmnopqrst' * 3]);
    // 每段 30 字符 + 段尾 2 换行 = 32 字符；宽 100、字号 10 → 每行 10 字符 → 4 行/段
    final pages = Paginator.paginate(
      doc,
      const ReaderPageConfig(
          width: 100, height: 100, fontSize: 10, lineHeight: 1.0, paragraphSpacing: 10),
    );

    // 行高 10、页高 100：页1 = p1(4行40) + 距10 + p2(4行40) → 用90；p3 放不下 → 页2 = p3(3行)
    // 注：join 后末段无尾随换行 → 30 字符 = 3 行
    expect(pages.length, 2);
    final totalLines = pages.fold(0, (n, p) => n + p.lines.length);
    expect(totalLines, 11);
    expect(pages[0].lines.length, 8);
    expect(pages.last.lines.first.segments.first.text, startsWith('klmnopqrst'));
  });

  test('分页保留行内样式（粗体）', () {
    final doc = const MdParser().parse('t', 'T', 'plain **bold** plain');
    final pages = Paginator.paginate(
      doc,
      const ReaderPageConfig(width: 1000, height: 500, fontSize: 10, lineHeight: 1.0),
    );
    expect(pages, isNotEmpty);
    final allSegs = pages.expand((p) => p.lines.expand((l) => l.segments)).toList();
    expect(allSegs.map((s) => s.text).join(), contains('bold'));
    expect(allSegs.any((s) => s.style == SegmentStyle.bold), isTrue);
  });

  test('空文档：不产生页面也不崩溃', () {
    final doc = _txtDoc([]);
    final pages = Paginator.paginate(
      doc,
      const ReaderPageConfig(width: 100, height: 100),
    );
    expect(pages, isEmpty);
  });
}
