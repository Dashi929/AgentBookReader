import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:agent_book_reader/core/parser/epub_extractor.dart';
import 'package:archive/archive.dart';

Archive buildEpub() {
  final arc = Archive();
  arc.addFile(ArchiveFile('mimetype', 20,
      utf8.encode('application/epub+zip')));
  arc.addFile(ArchiveFile(
      'META-INF/container.xml',
      0,
      utf8.encode('<?xml version="1.0"?><container><rootfiles>'
          '<rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>'
          '</rootfiles></container>')));
  arc.addFile(ArchiveFile(
      'OEBPS/content.opf',
      0,
      utf8.encode('<?xml version="1.0"?><package><manifest>'
          '<item id="c1" href="chap1.xhtml" media-type="application/xhtml+xml"/>'
          '<item id="c2" href="chap2.xhtml" media-type="application/xhtml+xml"/>'
          '</manifest><spine>'
          '<itemref idref="c1"/><itemref idref="c2"/>'
          '</spine></package>')));
  arc.addFile(ArchiveFile(
      'OEBPS/chap1.xhtml',
      0,
      utf8.encode('<?xml version="1.0"?><html><body>'
          '<h1>第一章</h1><p>正文<strong>加粗</strong>内容。</p>'
          '</body></html>')));
  arc.addFile(ArchiveFile(
      'OEBPS/chap2.xhtml',
      0,
      utf8.encode('<?xml version="1.0"?><html><body>'
          '<h2>第二章</h2><p>第二章内容。</p>'
          '</body></html>')));
  return arc;
}

void main() {
  test('EPUB 提取：spine 顺序 + 标题转 # + 粗体转 **', () {
    final bytes = ZipEncoder().encode(buildEpub());
    final md = EpubExtractor.extractAsMarkdown(bytes);

    expect(md, contains('# 第一章'));
    expect(md, contains('正文**加粗**内容。'));
    expect(md, contains('## 第二章'));
    // spine 顺序：第一章在前
    expect(md.indexOf('第一章'), lessThan(md.indexOf('第二章')));
  });

  test('EPUB 无 container.xml → 明确报错', () {
    final arc = Archive();
    arc.addFile(ArchiveFile('a.txt', 5, utf8.encode('hello')));
    final bytes = ZipEncoder().encode(arc);
    expect(() => EpubExtractor.extractAsMarkdown(bytes),
        throwsA(isA<FormatException>()));
  });
}
