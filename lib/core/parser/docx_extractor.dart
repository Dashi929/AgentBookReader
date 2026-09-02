import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:xml/xml.dart';

import '../model/char_range.dart';
import '../model/extracted_image.dart';

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
    return extractAsMarkdownWithImages(bytes).markdown;
  }

  /// 同 [extractAsMarkdown]，同时提取内嵌图片（w:drawing/a:blip → media），
  /// 在图片位置插入整行占位段 `[[IMG:imgN]]`。
  static ExtractionWithImages extractAsMarkdownWithImages(List<int> bytes) {
    final archive = ZipDecoder().decodeBytes(bytes);
    final mediaRels = _mediaRels(archive);
    final images = <ExtractedImage>[];
    final out = <String>[];

    final docXml = _findEntry(archive, 'word/document.xml');
    if (docXml != null) {
      final doc =
          XmlDocument.parse(utf8.decode(docXml.content, allowMalformed: true));
      final body = doc.findAllElements('w:body').firstOrNull;
      if (body != null) {
        for (final node in body.childElements) {
          final local = node.name.local;
          if (local == 'p') {
            final para = _extractParagraph(node);
            if (para != null) {
              final text = para.segments.map((s) => s.text).join().trim();
              if (text.isNotEmpty) {
                if (para.heading) {
                  out.add('# $text');
                } else {
                  out.add(para.segments
                      .map((s) => s.style == SegmentStyle.bold
                          ? '**${s.text}**'
                          : s.text)
                      .join()
                      .trim());
                }
              }
            }
            // 内嵌图片：w:drawing/a:blip[r:embed] → rels → media → 占位段
            for (final blip in node.findAllElements('a:blip')) {
              final rid =
                  blip.getAttribute('r:embed') ?? blip.getAttribute('embed');
              final mediaPath = rid == null ? null : mediaRels[rid];
              if (mediaPath == null) continue;
              final mediaFile = _findEntry(archive, mediaPath);
              if (mediaFile == null) continue;
              final id = 'img${images.length + 1}';
              images.add(ExtractedImage(
                  id: id,
                  bytes: Uint8List.fromList(mediaFile.content),
                  ext: mediaPath.split('.').last.toLowerCase()));
              out.add('[[IMG:$id]]');
            }
          } else if (local == 'tbl') {
            final text = _extractTable(node);
            if (text.isNotEmpty) out.add(text);
          }
        }
      }
    }
    return ExtractionWithImages(
        markdown: out.where((t) => t.isNotEmpty).join('\n\n'),
        images: images);
  }

  /// 解析 word/_rels/document.xml.rels：rId → media 路径（归一化到包根）。
  static Map<String, String> _mediaRels(Archive archive) {
    final relsFile = _findEntry(archive, 'word/_rels/document.xml.rels');
    if (relsFile == null) return {};
    try {
      final doc = XmlDocument.parse(
          utf8.decode(relsFile.content, allowMalformed: true));
      final map = <String, String>{};
      for (final rel in doc.findAllElements('Relationship')) {
        final id = rel.getAttribute('Id');
        final target = rel.getAttribute('Target');
        if (id != null &&
            target != null &&
            target.toLowerCase().contains('media')) {
          map[id] =
              target.startsWith('/') ? target.substring(1) : 'word/$target';
        }
      }
      return map;
    } catch (_) {
      return {};
    }
  }
}
