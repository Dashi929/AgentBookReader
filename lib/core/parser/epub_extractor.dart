import 'dart:convert';

import 'package:archive/archive.dart';
import 'package:xml/xml.dart';

/// .epub 提取：ZIP → META-INF/container.xml → OPF → spine 顺序 XHTML
/// → 每个文档的标题/段落转 Markdown（h1..h6 → #、strong/b → **）。
/// 宽容解析：ZIP 条目路径归一化、非严格 XHTML 降级为剥标签。
class EpubExtractor {
  EpubExtractor._();

  static ArchiveFile? _find(Archive archive, String path) {
    final target = path.toLowerCase();
    for (final f in archive.files) {
      if (f.name.replaceAll('\\', '/').toLowerCase() == target) return f;
    }
    return null;
  }

  /// 解析 container.xml 得到 OPF 路径。
  static String? _opfPath(Archive archive) {
    final container = _find(archive, 'META-INF/container.xml');
    if (container == null) return null;
    try {
      final doc = XmlDocument.parse(utf8.decode(container.content, allowMalformed: true));
      final rootfile = doc.findAllElements('rootfile').firstOrNull;
      return rootfile?.getAttribute('full-path');
    } catch (_) {
      return null;
    }
  }

  /// 解析 OPF 得到 spine 中的 XHTML href 列表（相对 OPF 目录）。
  static List<String> _spineHrefs(Archive archive, String opfPath) {
    final opfFile = _find(archive, opfPath);
    if (opfFile == null) return [];
    final doc = XmlDocument.parse(utf8.decode(opfFile.content, allowMalformed: true));

    final manifest = <String, String>{};
    for (final item in doc.findAllElements('item')) {
      final id = item.getAttribute('id');
      final href = item.getAttribute('href');
      final mediaType = item.getAttribute('media-type') ?? '';
      if (id != null && href != null && mediaType.contains('xhtml')) {
        manifest[id] = href;
      }
    }
    final hrefs = <String>[];
    for (final ref in doc.findAllElements('itemref')) {
      final idref = ref.getAttribute('idref');
      if (idref != null && manifest.containsKey(idref)) {
        final opfDir = opfPath.contains('/')
            ? opfPath.substring(0, opfPath.lastIndexOf('/') + 1)
            : '';
        hrefs.add('$opfDir${manifest[idref]}');
      }
    }
    return hrefs;
  }

  /// 提取为 Markdown。
  static String extractAsMarkdown(List<int> bytes) {
    final archive = ZipDecoder().decodeBytes(bytes);
    final opfPath = _opfPath(archive);
    if (opfPath == null) {
      throw const FormatException('不是有效的 .epub（缺少 container.xml）');
    }
    final hrefs = _spineHrefs(archive, opfPath);
    final out = <String>[];

    for (final href in hrefs) {
      final file = _find(archive, href);
      if (file == null) continue;
      String xhtml;
      try {
        xhtml = utf8.decode(file.content, allowMalformed: true);
      } catch (_) {
        continue;
      }

      XmlDocument doc;
      try {
        doc = XmlDocument.parse(xhtml);
      } catch (_) {
        // 非严格 XML：剥标签降级为纯文本
        final text = xhtml
            .replaceAll(RegExp(r'<[^>]+>'), ' ')
            .replaceAll(RegExp(r'\s{2,}'), ' ')
            .trim();
        if (text.isNotEmpty) out.add(text);
        continue;
      }

      final body = doc.findAllElements('body').firstOrNull;
      if (body == null) continue;

      for (final el in body.descendantElements) {
        final name = el.name.local.toLowerCase();
        if (name == 'p') {
          final text = _inlineMarkdown(el).trim();
          if (text.isNotEmpty) out.add(text);
        } else if (RegExp(r'^h[1-6]$').hasMatch(name)) {
          final level = int.parse(name.substring(1));
          final text = el.innerText.trim();
          if (text.isNotEmpty) {
            out.add('${'#' * level} $text');
          }
        }
      }
    }
    return out.join('\n\n');
  }

  /// 段内行内标记：strong/b → **粗体**，其余文本原样。
  static String _inlineMarkdown(XmlElement el) {
    final buf = StringBuffer();
    for (final node in el.children) {
      if (node is XmlText) {
        buf.write(node.value);
      } else if (node is XmlElement) {
        final name = node.name.local.toLowerCase();
        if (name == 'strong' || name == 'b') {
          final t = node.innerText.trim();
          if (t.isNotEmpty) buf.write('**$t**');
        } else if (name == 'br') {
          buf.write('\n');
        } else {
          buf.write(node.innerText);
        }
      }
    }
    return buf.toString();
  }
}
