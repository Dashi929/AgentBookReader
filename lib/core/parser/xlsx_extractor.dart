import 'dart:convert';

import 'package:archive/archive.dart';
import 'package:xml/xml.dart';

import '../model/book_metadata.dart';
import 'ooxml_core.dart';

/// .xlsx 提取：ZIP → workbook.xml（sheet 顺序/名称）→ worksheets →
/// 单元格文本转 Markdown 表格。图表/公式/样式不保留（文本管道）。
class XlsxExtractor {
  XlsxExtractor._();

  static ArchiveFile? _find(Archive archive, String path) {
    final target = path.toLowerCase();
    for (final f in archive.files) {
      if (f.name.replaceAll('\\', '/').toLowerCase() == target) return f;
    }
    return null;
  }

  /// rels Target 相对于 [baseDir] 解析（处理 ../ 与绝对路径）。
  static String _resolve(String baseDir, String target) {
    var t = target.replaceAll('\\', '/');
    var base = baseDir;
    while (t.startsWith('../')) {
      base = base.substring(0, base.lastIndexOf('/', base.length - 2) + 1);
      t = t.substring(3);
    }
    if (t.startsWith('/')) return t.substring(1);
    return '$base$t';
  }

  /// 提取为 Markdown：每个 sheet 一个 `# 标题` 节 + 表格（首行作表头）。
  /// 超过 [maxRows] 行的 sheet 截断并注明。
  static String extractAsMarkdown(List<int> bytes, {int maxRows = 500}) {
    final archive = ZipDecoder().decodeBytes(bytes);
    final wb = _find(archive, 'xl/workbook.xml');
    if (wb == null) {
      throw const FormatException('不是有效的 .xlsx（缺少 xl/workbook.xml）');
    }
    final shared = _sharedStrings(archive);
    final rels = _sheetRels(archive);
    final doc =
        XmlDocument.parse(OoxmlCore.stripNs(utf8.decode(wb.content, allowMalformed: true)));
    final out = StringBuffer();
    for (final sheet in doc.findAllElements('sheet')) {
      final name = sheet.getAttribute('name') ?? 'Sheet';
      final rid = sheet.getAttribute('r:id') ??
          sheet.getAttribute('id',
              namespaceUri:
                  'http://schemas.openxmlformats.org/officeDocument/2006/relationships');
      final target = rels[rid];
      if (target == null) continue;
      final f = _find(archive, _resolve('xl/', target));
      if (f == null) continue;
      out.writeln('# $name');
      out.writeln();
      out.writeln(_sheetTable(
          XmlDocument.parse(utf8.decode(f.content, allowMalformed: true)),
          shared,
          maxRows));
      out.writeln();
    }
    return out.toString();
  }

  static List<String> _sharedStrings(Archive archive) {
    final f = _find(archive, 'xl/sharedStrings.xml');
    if (f == null) return const [];
    try {
      final doc =
          XmlDocument.parse(OoxmlCore.stripNs(utf8.decode(f.content, allowMalformed: true)));
      return doc
          .findAllElements('si')
          .map((si) => si.findAllElements('t').map((t) => t.innerText).join())
          .toList();
    } catch (_) {
      return const [];
    }
  }

  /// workbook.xml.rels：rId → worksheet 部件路径。
  static Map<String, String> _sheetRels(Archive archive) {
    final f = _find(archive, 'xl/_rels/workbook.xml.rels');
    if (f == null) return const {};
    try {
      final doc =
          XmlDocument.parse(OoxmlCore.stripNs(utf8.decode(f.content, allowMalformed: true)));
      return {
        for (final r in doc.findAllElements('Relationship'))
          if ((r.getAttribute('Type') ?? '').endsWith('/worksheet'))
            r.getAttribute('Id')!: r.getAttribute('Target') ?? '',
      };
    } catch (_) {
      return const {};
    }
  }

  static String _sheetTable(XmlDocument doc, List<String> shared, int maxRows) {
    final rows = <List<String>>[];
    final allRows = doc.findAllElements('row').toList();
    var maxCols = 0;
    for (final row in allRows.take(maxRows)) {
      final cells = <String>[];
      for (final c in row.findAllElements('c')) {
        final colIdx = _colIndex(c.getAttribute('r') ?? '');
        final value = _cellText(c, shared);
        while (cells.length < colIdx) {
          cells.add('');
        }
        if (colIdx >= cells.length) {
          cells.add(value);
        } else if (cells[colIdx].isEmpty) {
          cells[colIdx] = value;
        }
      }
      if (cells.length > maxCols) maxCols = cells.length;
      rows.add(cells);
    }
    if (rows.isEmpty) return '（空表）';
    String rowText(List<String> r) {
      final padded = [...r];
      while (padded.length < maxCols) {
        padded.add('');
      }
      return '| ${padded.map(_escape).join(' | ')} |';
    }

    final buf = StringBuffer();
    buf.writeln(rowText(rows.first));
    buf.writeln('| ${List.filled(maxCols, '---').join(' | ')} |');
    for (var i = 1; i < rows.length; i++) {
      buf.writeln(rowText(rows[i]));
    }
    if (allRows.length > maxRows) {
      buf.writeln();
      buf.writeln('（仅显示前 $maxRows 行，共 ${allRows.length} 行）');
    }
    return buf.toString();
  }

  static String _cellText(XmlElement c, List<String> shared) {
    final t = c.getAttribute('t');
    if (t == 'inlineStr') {
      return c.findAllElements('t').map((e) => e.innerText).join();
    }
    final v = c.findAllElements('v').firstOrNull?.innerText ?? '';
    if (v.isEmpty) return '';
    if (t == 's') {
      final idx = int.tryParse(v);
      return idx != null && idx < shared.length ? shared[idx] : '';
    }
    if (t == 'b') return v == '1' ? 'TRUE' : 'FALSE';
    final d = double.tryParse(v);
    if (d != null && d == d.roundToDouble()) return d.toInt().toString();
    return v;
  }

  /// "A1" → 0，"AB3" → 27（列号从 0 开始）。
  static int _colIndex(String ref) {
    var n = 0;
    for (final ch in ref.codeUnits) {
      if (ch >= 0x41 && ch <= 0x5A) {
        n = n * 26 + (ch - 0x40);
      } else if (ch >= 0x61 && ch <= 0x7A) {
        n = n * 26 + (ch - 0x60);
      } else {
        break;
      }
    }
    return n <= 0 ? 0 : n - 1;
  }

  static String _escape(String s) =>
      s.replaceAll('|', '\\|').replaceAll('\n', ' ');

  /// 元数据：docProps/core.xml（dc:creator / dc:description）。
  static BookMetadata extractMetadata(List<int> bytes) =>
      OoxmlCore.extract(bytes);

  // —— 供结构化解析（parseXlsxSheets）复用 ——

  static String resolveRels(String baseDir, String target) =>
      _resolve(baseDir, target);

  static int colIndexOf(String ref) => _colIndex(ref);

  static int rowIndexOf(String ref) {
    final digits = RegExp(r'\d+').firstMatch(ref)?.group(0);
    return (int.tryParse(digits ?? '1') ?? 1) - 1;
  }
}

//================ 结构化解析（供网格视图渲染，Office 视觉近似） ================

/// 单元格渲染数据。
class XlsxCellData {
  String text = '';
  bool bold = false;
  bool number = false; // 数字右对齐
  String align = ''; // left|right|center
}

/// 单个工作表的渲染数据（列宽字符数、行高 pt、合并区域）。
class XlsxSheetData {
  XlsxSheetData(this.name, this.rows, this.cols, this.cells,
      this.colWidths, this.rowHeights, this.merges);
  final String name;
  final int rows; // 行数
  final int cols; // 列数
  final Map<int, Map<int, XlsxCellData>> cells; // row→col→cell
  final List<double> colWidths; // Excel 字符宽度单位
  final List<double> rowHeights; // pt
  final List<List<int>> merges; // [r1,c1,r2,c2] 闭区间
}

class _XlsxStyle {
  bool bold = false;
  String align = '';
}

/// 解析工作簿为渲染数据（样式：字体加粗/对齐；合并单元格；列宽行高）。
/// 复用 [XlsxExtractor.extractAsMarkdown] 的 ZIP/rels 工具（此处独立解析）。
List<XlsxSheetData> parseXlsxSheets(List<int> bytes) {
  final archive = ZipDecoder().decodeBytes(bytes);
  ArchiveFile? find(String path) {
    final bs = String.fromCharCode(92); // 反斜杠
    final t = path.replaceAll(bs, '/').toLowerCase();
    for (final f in archive.files) {
      if (f.name.replaceAll(bs, '/').toLowerCase() == t) return f;
    }
    return null;
  }

  // styles.xml：fonts（加粗）+ cellXfs（fontId、对齐）
  final styles = <_XlsxStyle>[];
  final stylesFile = find('xl/styles.xml');
  if (stylesFile != null) {
    final doc = XmlDocument.parse(
        OoxmlCore.stripNs(utf8.decode(stylesFile.content, allowMalformed: true)));
    final boldFlags = <bool>[];
    for (final f in doc.findAllElements('font')) {
      boldFlags.add(f.findAllElements('b').isNotEmpty);
    }
    for (final xf in doc.findAllElements('xf')) {
      final st = _XlsxStyle();
      final fontId = int.tryParse(xf.getAttribute('fontId') ?? '0') ?? 0;
      if (fontId >= 0 && fontId < boldFlags.length) st.bold = boldFlags[fontId];
      final alignment = xf.findAllElements('alignment').firstOrNull;
      st.align = alignment?.getAttribute('horizontal') ?? '';
      styles.add(st);
    }
  }

  final shared = <String>[];
  final ssFile = find('xl/sharedStrings.xml');
  if (ssFile != null) {
    final doc = XmlDocument.parse(
        OoxmlCore.stripNs(utf8.decode(ssFile.content, allowMalformed: true)));
    for (final si in doc.findAllElements('si')) {
      shared.add(si.findAllElements('t').map((t) => t.innerText).join());
    }
  }

  final out = <XlsxSheetData>[];
  final wbFile = find('xl/workbook.xml');
  final relsFile = find('xl/_rels/workbook.xml.rels');
  if (wbFile == null || relsFile == null) return out;
  final wb = XmlDocument.parse(
      OoxmlCore.stripNs(utf8.decode(wbFile.content, allowMalformed: true)));
  final rels = XmlDocument.parse(OoxmlCore.stripNs(
      utf8.decode(relsFile.content, allowMalformed: true)));
  final relMap = <String, String>{};
  for (final r in rels.findAllElements('Relationship')) {
    if ((r.getAttribute('Type') ?? '').endsWith('/worksheet')) {
      relMap[r.getAttribute('Id')!] = r.getAttribute('Target') ?? '';
    }
  }
  for (final sheet in wb.findAllElements('sheet')) {
    final name = sheet.getAttribute('name') ?? 'Sheet';
    final target = relMap[sheet.getAttribute('r:id')];
    final f = target == null
        ? null
        : find(XlsxExtractor.resolveRels('xl/', target));
    if (f == null) continue;
    final doc = XmlDocument.parse(
        OoxmlCore.stripNs(utf8.decode(f.content, allowMalformed: true)));

    final cells = <int, Map<int, XlsxCellData>>{};
    var maxRow = 0, maxCol = 0;
    for (final row in doc.findAllElements('row')) {
      final rIdx = (int.tryParse(row.getAttribute('r') ?? '') ?? 1) - 1;
      if (rIdx > maxRow) maxRow = rIdx;
      for (final c in row.findAllElements('c')) {
        final cIdx = XlsxExtractor.colIndexOf(c.getAttribute('r') ?? '');
        final styleIdx = int.tryParse(c.getAttribute('s') ?? '') ?? -1;
        final st =
            styleIdx >= 0 && styleIdx < styles.length ? styles[styleIdx] : null;
        final t = c.getAttribute('t');
        String text;
        var isNumber = false;
        if (t == 'inlineStr') {
          text = c.findAllElements('t').map((e) => e.innerText).join();
        } else {
          final v = c.findAllElements('v').firstOrNull?.innerText ?? '';
          if (v.isEmpty) continue;
          if (t == 's') {
            final idx = int.tryParse(v);
            text = idx != null && idx < shared.length ? shared[idx] : '';
          } else if (t == 'b') {
            text = v == '1' ? 'TRUE' : 'FALSE';
          } else {
            final d = double.tryParse(v);
            if (d != null && d == d.roundToDouble()) {
              text = d.toInt().toString();
            } else {
              text = v;
            }
            isNumber = t == null || t == 'n';
          }
        }
        if (text.isEmpty) continue;
        if (cIdx > maxCol) maxCol = cIdx;
        (cells[rIdx] ??= {})[cIdx] = XlsxCellData()
          ..text = text
          ..bold = st?.bold ?? false
          ..number = isNumber
          ..align = st?.align ?? (isNumber ? 'right' : '');
      }
    }

    // 列宽：<col min max width/>；默认 8.43
    double defaultW = 8.43;
    final fmtPr = doc.findAllElements('sheetFormatPr').firstOrNull;
    defaultW =
        double.tryParse(fmtPr?.getAttribute('defaultColWidth') ?? '') ?? 8.43;
    final colEls = doc.findAllElements('col').toList();
    double widthFor(int idx) {
      for (final col in colEls) {
        final min = int.tryParse(col.getAttribute('min') ?? '') ?? 0;
        final max = int.tryParse(col.getAttribute('max') ?? '') ?? 0;
        if (idx + 1 >= min && idx + 1 <= max) {
          return double.tryParse(col.getAttribute('width') ?? '') ?? defaultW;
        }
      }
      return defaultW;
    }

    final rowH = <double>[];
    double defaultH =
        double.tryParse(fmtPr?.getAttribute('defaultRowHeight') ?? '') ?? 15.0;
    for (final row in doc.findAllElements('row')) {
      final rIdx = (int.tryParse(row.getAttribute('r') ?? '') ?? 1) - 1;
      while (rowH.length < rIdx) {
        rowH.add(defaultH);
      }
      rowH.add(double.tryParse(row.getAttribute('ht') ?? '') ?? defaultH);
    }

    final merges = <List<int>>[];
    for (final m in doc.findAllElements('mergeCell')) {
      final ref = (m.getAttribute('ref') ?? '').split(':');
      if (ref.length == 2) {
        merges.add([
          XlsxExtractor.rowIndexOf(ref[0]),
          XlsxExtractor.colIndexOf(ref[0]),
          XlsxExtractor.rowIndexOf(ref[1]),
          XlsxExtractor.colIndexOf(ref[1]),
        ]);
      }
    }

    out.add(XlsxSheetData(
        name,
        maxRow + 1,
        maxCol + 1,
        cells,
        [for (var i = 0; i < maxCol + 1; i++) widthFor(i)],
        [for (var i = 0; i < maxRow + 1; i++) i < rowH.length ? rowH[i] : defaultH],
        merges));
  }
  return out;
}
