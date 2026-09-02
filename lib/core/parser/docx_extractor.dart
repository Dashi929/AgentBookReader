import 'dart:convert';

import 'package:archive/archive.dart';
import 'package:xml/xml.dart';

import '../model/char_range.dart';

/// .docx 文本提取：解包 ZIP → `word/document.xml` →
/// `w:p` 段落 / `w:t` 文本 / `w:b` 粗体 / 标题样式 → 轻量段落结构。
/// 只做读取转换；样式/表格/图片简化为文本（表格单元格以空格连接）。
class DocxExtractor {
  DocxExtractor._();

  /// 归一化查找 ZIP 条目（兼容反斜杠条目名与大小写差异）。
  static ArchiveFile? _findEntry(Archive archive, String path) {
    final target = path.toLowerCase();
    for (final f in archive.files) {
      if (f.name.replaceAll('\\', '/').toLowerCase() == target) return f;
    }
    return null;
  }

  /// 提取为带样式的段落（\n\n 分隔的纯文本由调用方再分页）。
  /// 返回：每段 (segments, isHeading)。
  static List<({List<RichSegment> segments, bool heading})> extract(
      List<int> bytes) {
    final archive = ZipDecoder().decodeBytes(bytes);
    final docXml = _findEntry(archive, 'word/document.xml');
    if (docXml == null) {
      throw const FormatException('不是有效的 .docx（缺少 word/document.xml）');
    }
    final xmlText = utf8.decode(docXml.content, allowMalformed: true);
    final doc = XmlDocument.parse(xmlText);

    final out = <({List<RichSegment> segments, bool heading})>[];
    // 只遍历 body 的直接段落与表格，忽略 sectPr 等
    final body = doc.findAllElements('w:body').firstOrNull;
    if (body == null) return out;

    for (final node in body.childElements) {
      final local = node.name.local;
      if (local == 'p') {
        final para = _extractParagraph(node);
        if (para != null) out.add(para);
      } else if (local == 'tbl') {
        final text = _extractTable(node);
        if (text.isNotEmpty) {
          out.add((segments: [RichSegment.styled(text, SegmentStyle.normal)], heading: false));
        }
      }
    }
    return out;
  }

  /// 段落文本 + 样式；空段落返回 null。
  static ({List<RichSegment> segments, bool heading})? _extractParagraph(
      XmlElement p) {
    final segments = <RichSegment>[];
    final buffer = StringBuffer();

    void flush() {
      if (buffer.isEmpty) return;
      segments.add(RichSegment.styled(buffer.toString(), SegmentStyle.normal));
      buffer.clear();
    }

    var heading = false;
    for (final r in p.findAllElements('w:r')) {
      final style = r.getElement('w:rPr');
      final isBold = style?.getElement('w:b') != null;
      final texts = r.findElements('w:t');
      for (final t in texts) {
        final v = t.innerText;
        if (v.isEmpty) continue;
        if (isBold) {
          flush();
          segments.add(RichSegment.styled(v, SegmentStyle.bold));
        } else {
          buffer.write(v);
        }
      }
      if (r.findElements('w:tab').isNotEmpty) buffer.write('  ');
      if (r.findElements('w:br').isNotEmpty) buffer.write('\n');
    }

    // 标题样式（Heading1/2/3）→ 整段视为标题
    final pPr = p.getElement('w:pPr');
    final pStyle = pPr?.getElement('w:pStyle')?.getAttribute('w:val') ?? '';
    if (RegExp(r'^(Heading|heading)[1-6]$|^T[íi]tulo[1-6]$|^标题\s?[1-6]$').hasMatch(pStyle)) {
      heading = true;
    }

    flush();
    if (segments.isEmpty) return null;
    return (segments: segments, heading: heading);
  }

  static String _extractTable(XmlElement tbl) {
    final rows = <String>[];
    for (final tr in tbl.findAllElements('w:tr')) {
      final cells = <String>[];
      for (final tc in tr.findElements('w:tc')) {
        final cellText = tc
            .findAllElements('w:t')
            .map((t) => t.innerText)
            .join()
            .trim();
        cells.add(cellText);
      }
      if (cells.any((c) => c.isNotEmpty)) rows.add(cells.join('  |  '));
    }
    return rows.join('\n');
  }

  /// 提取为纯文本（\n\n 分隔段落），供统一解析管道使用。
  static String extractText(List<int> bytes) {
    final paras = extract(bytes);
    return paras
        .map((p) => p.segments.map((s) => s.text).join().trim())
        .where((t) => t.isNotEmpty)
        .join('\n\n');
  }

  /// 提取为 Markdown（标题段落转 `#`，粗体转 `**`），
  /// 交给 MdParser 解析即可获得按标题切分的 Section。
  static String extractAsMarkdown(List<int> bytes) {
    final paras = extract(bytes);
    final out = <String>[];
    for (final p in paras) {
      final text = p.segments.map((s) => s.text).join().trim();
      if (text.isEmpty) continue;
      if (p.heading) {
        out.add('# $text');
      } else {
        final rendered = p.segments
            .map((s) => s.style == SegmentStyle.bold ? '**${s.text}**' : s.text)
            .join();
        out.add(rendered.trim());
      }
    }
    return out.join('\n\n');
  }
}
