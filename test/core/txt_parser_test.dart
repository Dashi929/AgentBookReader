import 'package:flutter_test/flutter_test.dart';
import 'package:agent_book_reader/core/parser/txt_parser.dart';

void main() {
  const parser = TxtParser(sectionSize: 3);

  test('空行分段 + 偏移量精确', () {
    final raw = '第一段第一行\n第一段第二行\n\n第二段\n\n第三段';
    final doc = parser.parse('d1', '测试', raw);

    expect(doc.sections.length, 1); // 3 段 → 1 个 Section
    final paragraphs = doc.sections.first.paragraphs;
    expect(paragraphs.length, 3);

    // 覆盖不变式：首段从头开始，末段到文末
    expect(paragraphs.first.charOffset, 0);
    final last = paragraphs.last;
    expect(last.charOffset + last.length, raw.length);

    // 每段的切片 == 原文对应位置
    for (final p in paragraphs) {
      expect(raw.substring(p.charOffset, p.charOffset + p.length),
          p.plainText);
    }
  });

  test('段落按 sectionSize 切 Section', () {
    final raw = List.generate(7, (i) => '段落$i').join('\n\n');
    final doc = parser.parse('d2', '测试', raw);
    expect(doc.sections.length, 3); // 3+3+1
    expect(doc.sections[0].title, contains('段落0'));
    expect(doc.sections[2].paragraphs.length, 1);
  });

  test('超长段硬切（maxGroupLines）', () {
    const parser2 = TxtParser(sectionSize: 10, maxGroupLines: 5);
    final raw = List.generate(12, (i) => '行$i').join('\n'); // 无空行
    final doc = parser2.parse('d3', '测试', raw);
    // 12 行 → 5+5+2 = 3 段
    expect(doc.sections.first.paragraphs.length, 3);
  });

  test('空文档', () {
    final doc = parser.parse('d4', '空', '');
    expect(doc.sections, isNotEmpty);
    expect(doc.charCount, 0);
  });

  test('CRLF 换行', () {
    final raw = '甲\r\n\r\n乙\r\n';
    final doc = parser.parse('d5', '测试', raw);
    final p = doc.sections.first.paragraphs;
    expect(p.length, 2);
    expect(raw.substring(p.last.charOffset, p.last.charOffset + p.last.length),
        p.last.plainText);
  });
}
