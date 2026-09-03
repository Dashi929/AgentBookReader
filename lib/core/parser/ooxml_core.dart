import 'dart:convert';

import 'package:archive/archive.dart';
import 'package:xml/xml.dart';

import '../model/book_metadata.dart';

/// OOXML 包通用：docProps/core.xml 元数据（xlsx/pptx 共用）。
class OoxmlCore {
  OoxmlCore._();

  /// OOXML 文档常用 p:/a:/c: 等命名空间前缀，而 xml 包的
  /// findAllElements 按限定名匹配。解析前剥掉元素名前缀
  /// （xmlns 声明与属性前缀保留，r:id/r:embed 走 namespaceUri 查询）。
  static String stripNs(String xml) =>
      xml.replaceAllMapped(RegExp(r'(<[/]?)[A-Za-z0-9]+:'), (m) => m.group(1)!);

  static BookMetadata extract(List<int> bytes) {
    try {
      final archive = ZipDecoder().decodeBytes(bytes);
      ArchiveFile? core;
      for (final f in archive.files) {
        if (f.name.replaceAll('\\', '/').toLowerCase() ==
            'docprops/core.xml') {
          core = f;
          break;
        }
      }
      if (core == null) return const BookMetadata();
      final doc =
          XmlDocument.parse(utf8.decode(core.content, allowMalformed: true));
      String pick(String name) {
        for (final n in [name, 'dc:$name']) {
          final e = doc.findAllElements(n).firstOrNull;
          if (e != null) return e.innerText.trim();
        }
        return '';
      }

      return BookMetadata(author: pick('creator'), synopsis: pick('description'));
    } catch (_) {
      return const BookMetadata();
    }
  }
}
