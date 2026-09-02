import 'package:flutter_test/flutter_test.dart';
import 'package:agent_book_reader/core/parser/json_parser.dart';

void main() {
  const parser = JsonParser();

  test('对象根：顶层键各成 Section，键名为标题', () {
    final raw = '{\n  "name": "AgentBookReader",\n  "tags": ["a", "b"],\n  "meta": {"stars": 5}\n}';
    final doc = parser.parse('d1', '配置', raw);

    expect(doc.sections.length, 3);
    expect(doc.sections[0].title, 'name');
    expect(doc.sections[1].title, 'tags');
    expect(doc.sections[2].title, 'meta');

    // 切片精确：每段切片 == 原文对应区间
    for (final s in doc.sections) {
      for (final p in s.paragraphs) {
        expect(raw.substring(p.charOffset, p.charOffset + p.length), p.plainText);
      }
    }
    // 含转义字符串的成员也不被字符串内的逗号/括号干扰
    expect(doc.sections[0].plainText, contains('AgentBookReader'));
    expect(doc.sections[1].plainText, contains('"a"'));
  });

  test('数组根：元素各成 Section，标签 [i]', () {
    final raw = '[1, {"x": 2}, "三"]';
    final doc = parser.parse('d2', '数据', raw);
    expect(doc.sections.length, 3);
    expect(doc.sections[0].title, '[0]');
    expect(doc.sections[1].title, '[1]');
    expect(doc.sections[2].title, '[2]');
    expect(doc.sections[1].plainText, contains('"x"'));
  });

  test('字符串内逗号/括号不干扰切分', () {
    final raw = '{"a": "含,逗号与}花括号", "b": 2}';
    final doc = parser.parse('d3', '书', raw);
    expect(doc.sections.length, 2);
    expect(doc.sections[0].plainText, contains('含,逗号与}花括号'));
  });

  test('原始值根：回退单 Section 覆盖全文', () {
    final raw = '"just a string"';
    final doc = parser.parse('d4', '书', raw);
    expect(doc.sections.length, 1);
    expect(doc.sections.first.plainText, raw);
  });
}
