import 'package:flutter_test/flutter_test.dart';
import 'package:agent_book_reader/core/controller/plain_text_document.dart';
import 'package:agent_book_reader/core/model/annotation.dart';
import 'package:agent_book_reader/core/model/char_range.dart';

void main() {
  test('create/search：大小写不敏感 + 返回区间', () async {
    final doc = await PlainTextDocument.create('d1', '书', DocFormat.txt,
        'Hello World\n\n第二段包含 hello 关键词');
    final hits = doc.search('hello');
    expect(hits.length, 2);
    expect(doc.rawText.substring(hits[0].range.start, hits[0].range.end),
        'Hello');
  });

  test('applyEdit：替换后重解析且原文更新', () async {
    final doc = await PlainTextDocument.create('d2', '书', DocFormat.txt,
        '第一段\n\n旧文本待改');
    final target = doc.search('旧文本').first;
    final newDoc = await doc
        .applyEdit(DocTextEdit.replace(target.range, '新文本已改'));

    expect(doc.rawText, contains('新文本已改'));
    expect(doc.rawText, isNot(contains('旧文本')));
    expect(newDoc.charCount, doc.charCount);
    expect(doc.search('旧文本'), isEmpty);
  });

  test('textAt：区间裁剪安全', () async {
    final doc = await PlainTextDocument.create('d3', '书', DocFormat.txt, 'abc');
    expect(doc.textAt(const CharRange(0, 100)), 'abc');
    expect(doc.textAt(const CharRange(-5, 2)), 'ab');
  });

  test('md 文档加载：sectionAt 定位', () async {
    final doc = await PlainTextDocument.create('d4', '书', DocFormat.md,
        '# 甲\n内容\n\n# 乙\n内容2');
    expect(doc.sectionCount, 2);
    expect(doc.sectionAt(1)?.title, '乙');
    expect(doc.sectionAt(9), isNull);
  });
}
