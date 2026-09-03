import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:agent_book_reader/core/parser/cbz_extractor.dart';
import 'package:agent_book_reader/core/parser/pptx_extractor.dart';
import 'package:agent_book_reader/core/parser/xlsx_extractor.dart';
import 'package:archive/archive.dart';

Archive _xlsx() {
  final arc = Archive();
  arc.addFile(ArchiveFile(
      'xl/workbook.xml',
      0,
      utf8.encode('<?xml version="1.0"?><workbook xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><sheets>'
          '<sheet name="成绩表" sheetId="1" r:id="rId1"/>'
          '<sheet name="空表" sheetId="2" r:id="rId2"/>'
          '</sheets></workbook>')));
  arc.addFile(ArchiveFile(
      'xl/_rels/workbook.xml.rels',
      0,
      utf8.encode('<?xml version="1.0"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
          '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/>'
          '<Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet2.xml"/>'
          '</Relationships>')));
  arc.addFile(ArchiveFile(
      'xl/sharedStrings.xml',
      0,
      utf8.encode('<?xml version="1.0"?><sst count="3" uniqueCount="3">'
          '<si><t>姓名</t></si><si><t>语文</t></si><si><t>张三|李四</t></si>'
          '</sst>')));
  arc.addFile(ArchiveFile(
      'xl/worksheets/sheet1.xml',
      0,
      utf8.encode('<?xml version="1.0"?><worksheet><sheetData>'
          '<row r="1"><c r="A1" t="s"><v>0</v></c><c r="B1" t="s"><v>1</v></c></row>'
          '<row r="2"><c r="A2" t="s"><v>2</v></c><c r="B2"><v>95.5</v></c></row>'
          '<row r="3"><c r="A3"><v>2</v></c></row>'
          '</sheetData></worksheet>')));
  arc.addFile(ArchiveFile(
      'xl/worksheets/sheet2.xml',
      0,
      utf8.encode('<?xml version="1.0"?><worksheet><sheetData></sheetData></worksheet>')));
  return arc;
}

Archive _pptx() {
  final arc = Archive();
  arc.addFile(ArchiveFile(
      'ppt/presentation.xml',
      0,
      utf8.encode('<?xml version="1.0"?><presentation xmlns="http://schemas.openxmlformats.org/presentationml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">'
          '<sldIdLst><sldId id="256" r:id="rId2"/></sldIdLst></presentation>')));
  arc.addFile(ArchiveFile(
      'ppt/_rels/presentation.xml.rels',
      0,
      utf8.encode('<?xml version="1.0"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
          '<Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slide" Target="slides/slide1.xml"/>'
          '</Relationships>')));
  arc.addFile(ArchiveFile(
      'ppt/slides/slide1.xml',
      0,
      utf8.encode('<?xml version="1.0"?><sld xmlns="http://schemas.openxmlformats.org/presentationml/2006/main" xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">'
          '<cSld><spTree>'
          '<sp><nvSpPr><cNvPr/><nvPr><ph type="title"/></nvPr></nvSpPr>'
          '<txBody><a:p><a:r><a:t>开场标题</a:t></a:r></a:p></txBody></sp>'
          '<sp><txBody><a:p><a:r><a:t>第一行要点</a:t></a:r></a:p>'
          '<a:p><a:r><a:t>第二行要点</a:t></a:r></a:p></txBody></sp>'
          '<pic><blipFill><a:blip r:embed="rId3"/></blipFill></pic>'
          '</spTree></cSld></sld>')));
  arc.addFile(ArchiveFile(
      'ppt/slides/_rels/slide1.xml.rels',
      0,
      utf8.encode('<?xml version="1.0"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
          '<Relationship Id="rId3" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/image" Target="../media/image1.png"/>'
          '</Relationships>')));
  arc.addFile(ArchiveFile('ppt/media/image1.png', 4, utf8.encode('IMG1')));
  return arc;
}

Archive _cbz() {
  final arc = Archive();
  arc.addFile(ArchiveFile('page10.jpg', 5, utf8.encode('PAGE10')));
  arc.addFile(ArchiveFile('page2.jpg', 5, utf8.encode('PAGE2')));
  arc.addFile(ArchiveFile('cover.png', 6, utf8.encode('COVERP')));
  arc.addFile(ArchiveFile('info.txt', 5, utf8.encode('skip!')));
  return arc;
}

void main() {
  test('XLSX：sheet 名→节标题，共享字符串/数值/跳列，首行作表头', () {
    final md = XlsxExtractor.extractAsMarkdown(ZipEncoder().encode(_xlsx()));
    expect(md, contains('# 成绩表'));
    expect(md, contains('| 姓名 | 语文 |'));
    expect(md, contains('张三\\|李四')); // 单元格内的 | 需转义
    expect(md, contains('95.5'));
    expect(md, contains('| 2 |  |')); // 跳列补空
    expect(md, contains('# 空表'));
    expect(md, contains('（空表）'));
  });

  test('XLSX 元数据：docProps/core.xml', () {
    final arc = _xlsx();
    arc.addFile(ArchiveFile(
        'docProps/core.xml',
        0,
        utf8.encode('<?xml version="1.0"?><cp:coreProperties '
            'xmlns:dc="http://purl.org/dc/elements/1.1/">'
            '<dc:creator>表格君</dc:creator></cp:coreProperties>')));
    final meta = XlsxExtractor.extractMetadata(ZipEncoder().encode(arc));
    expect(meta.author, '表格君');
  });

  test('PPTX：标题占位符→节标题 + 正文段落 + 图片占位符', () {
    final r = PptxExtractor.extractAsMarkdownWithImages(ZipEncoder().encode(_pptx()));
    expect(r.markdown, contains('# 开场标题'));
    expect(r.markdown, contains('第一行要点'));
    expect(r.markdown, contains('[[IMG:img1]]'));
    expect(r.images, hasLength(1));
    expect(utf8.decode(r.images.first.bytes), 'IMG1');
    expect(r.images.first.ext, 'png');
  });

  test('PPTX 非法文件 → FormatException', () {
    final arc = Archive();
    arc.addFile(ArchiveFile('a.txt', 5, utf8.encode('hello')));
    expect(() => PptxExtractor.extractAsMarkdown(ZipEncoder().encode(arc)),
        throwsA(isA<FormatException>()));
  });

  test('CBZ：图片自然排序（cover → page2 → page10），非图片跳过', () {
    final r = CbzExtractor.extractPages(ZipEncoder().encode(_cbz()));
    expect(r.images.map((i) => utf8.decode(i.bytes)).toList(),
        ['COVERP', 'PAGE2', 'PAGE10']);
    expect(r.markdown.split('[[IMG:').length - 1, 3);
    expect(r.markdown, startsWith('# 漫画'));
  });

  test('CBZ 无图片 → FormatException', () {
    final arc = Archive();
    arc.addFile(ArchiveFile('a.txt', 5, utf8.encode('hello')));
    expect(() => CbzExtractor.extractPages(ZipEncoder().encode(arc)),
        throwsA(isA<FormatException>()));
  });
}
