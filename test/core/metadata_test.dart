import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:agent_book_reader/core/parser/epub_extractor.dart';
import 'package:agent_book_reader/core/parser/docx_extractor.dart';
import 'package:archive/archive.dart';

Archive _epubWithMeta({bool withCover = true}) {
  final coverPng = <int>[
    0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, // PNG 魔数
    0, 0, 0, 13, 0x49, 0x48, 0x44, 0x52, // IHDR
    0, 0, 0, 1, 0, 0, 0, 1, 8, 2, 0, 0, 0, // 1x1
    0x90, 0x77, 0x53, 0xDE, 0, 0, 0, 0, 0x49, 0x45, 0x4E, 0x44, 0xAE, 0x42,
    0x60, 0x82,
  ];
  final coverItem = withCover
      ? '<item id="cover-image" href="images/cover.png" '
          'media-type="image/png" properties="cover-image"/>'
      : '';
  final arc = Archive();
  arc.addFile(ArchiveFile('mimetype', 20, utf8.encode('application/epub+zip')));
  arc.addFile(ArchiveFile(
      'META-INF/container.xml',
      0,
      utf8.encode('<?xml version="1.0"?><container><rootfiles>'
          '<rootfile full-path="OEBPS/content.opf"/>'
          '</rootfiles></container>')));
  arc.addFile(ArchiveFile(
      'OEBPS/content.opf',
      0,
      utf8.encode('<?xml version="1.0"?>'
          '<package xmlns:dc="http://purl.org/dc/elements/1.1/">'
          '<metadata>'
          '<dc:title>测试书</dc:title>'
          '<dc:creator>张三</dc:creator>'
          '<dc:description>这是&lt;b&gt;简介&lt;/b&gt;内容。</dc:description>'
          '</metadata>'
          '<manifest>$coverItem'
          '<item id="c1" href="chap1.xhtml" media-type="application/xhtml+xml"/>'
          '</manifest><spine><itemref idref="c1"/></spine></package>')));
  arc.addFile(ArchiveFile(
      'OEBPS/chap1.xhtml',
      0,
      utf8.encode('<?xml version="1.0"?><html><body><h1>一</h1>'
          '<p>正文</p></body></html>')));
  if (withCover) {
    arc.addFile(ArchiveFile('OEBPS/images/cover.png', coverPng.length, coverPng));
  }
  return arc;
}

Archive _docxWithMeta() {
  final arc = Archive();
  arc.addFile(ArchiveFile(
      '[Content_Types].xml', 0, utf8.encode('<Types/>')));
  arc.addFile(ArchiveFile(
      'docProps/core.xml',
      0,
      utf8.encode('<?xml version="1.0"?>'
          '<cp:coreProperties xmlns:cp="x" xmlns:dc="http://purl.org/dc/elements/1.1/">'
          '<dc:creator>李四</dc:creator>'
          '<dc:description>文档简介</dc:description>'
          '</cp:coreProperties>')));
  arc.addFile(ArchiveFile(
      'word/document.xml',
      0,
      utf8.encode('<?xml version="1.0"?>'
          '<w:document xmlns:w="w"><w:body>'
          '<w:p><w:r><w:t>段落</w:t></w:r></w:p>'
          '</w:body></w:document>')));
  arc.addFile(ArchiveFile(
      'word/media/image1.png', 0, utf8.encode('FAKEPNGDATA')));
  return arc;
}

void main() {
  test('EPUB 元数据：作者 + 简介（剥标签）+ 封面字节', () {
    final meta = EpubExtractor.extractMetadata(ZipEncoder().encode(_epubWithMeta()));
    expect(meta.author, '张三');
    expect(meta.synopsis, contains('简介内容'));
    expect(meta.synopsis.contains('<b>'), isFalse);
    expect(meta.hasCover, isTrue);
    expect(meta.coverExt, 'png');
    expect(meta.coverBytes!.first, 0x89);
  });

  test('EPUB 无元数据 → 空值不报错', () {
    final meta =
        EpubExtractor.extractMetadata(ZipEncoder().encode(_epubWithMeta(withCover: false)));
    expect(meta.author, '张三'); // 元数据仍在，只是没有封面
    expect(meta.hasCover, isFalse);
  });

  test('EPUB 非法文件 → 空 BookMetadata', () {
    final arc = Archive();
    arc.addFile(ArchiveFile('a.txt', 5, utf8.encode('hello')));
    final meta = EpubExtractor.extractMetadata(ZipEncoder().encode(arc));
    expect(meta.author, isEmpty);
    expect(meta.hasCover, isFalse);
  });

  test('DOCX 元数据：core.xml 作者/简介 + 首个 media 图片', () {
    final meta = DocxExtractor.extractMetadata(ZipEncoder().encode(_docxWithMeta()));
    expect(meta.author, '李四');
    expect(meta.synopsis, '文档简介');
    expect(meta.hasCover, isTrue);
    expect(meta.coverExt, 'png');
  });
}
