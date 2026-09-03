import 'dart:typed_data';

import 'package:archive/archive.dart';

import '../model/book_metadata.dart';
import '../model/extracted_image.dart';

/// .cbz 漫画包提取：ZIP 内图片按自然顺序（文件名数字感知排序）编为页面，
/// 每页一个 `[[IMG:imgN]]` 整行占位段，复用 docx/epub 的图片渲染管线。
/// 不支持 .cbr（RAR 格式，无开源纯 Dart 解码器）。
class CbzExtractor {
  CbzExtractor._();

  static const _imgExts = {'png', 'jpg', 'jpeg', 'gif', 'bmp', 'webp'};

  static bool isImageEntry(String name) {
    final n = name.replaceAll('\\', '/').toLowerCase();
    if (n.contains('/__macosx/')) return false;
    return _imgExts.contains(n.split('.').last);
  }

  /// 文件名自然排序：数字段按数值比较（page2 < page10）。
  static int naturalCompare(String a, String b) {
    final an = _naturalKey(a);
    final bn = _naturalKey(b);
    for (var i = 0; i < an.length && i < bn.length; i++) {
      final x = an[i], y = bn[i];
      if (x is int && y is int) {
        final c = x.compareTo(y);
        if (c != 0) return c;
      } else {
        final c = x.toString().compareTo(y.toString());
        if (c != 0) return c;
      }
    }
    return an.length.compareTo(bn.length);
  }

  static List<Object> _naturalKey(String s) {
    final keys = <Object>[];
    final buf = StringBuffer();
    var digits = false;
    for (final ch in s.split('')) {
      final d = int.tryParse(ch) != null;
      if (d != digits && buf.isNotEmpty) {
        keys.add(digits ? int.parse(buf.toString()) : buf.toString());
        buf.clear();
      }
      digits = d;
      buf.write(ch);
    }
    if (buf.isNotEmpty) {
      keys.add(digits ? int.parse(buf.toString()) : buf.toString());
    }
    return keys;
  }

  /// 提取为 Markdown（整本只有图片占位段，每页一段）。
  static ExtractionWithImages extractPages(List<int> bytes) {
    final archive = ZipDecoder().decodeBytes(bytes);
    final pages = archive.files
        .where((f) => f.isFile && isImageEntry(f.name))
        .toList()
      ..sort((a, b) => naturalCompare(
          a.name.replaceAll('\\', '/'), b.name.replaceAll('\\', '/')));
    final md = StringBuffer('# 漫画\n\n');
    final images = <ExtractedImage>[];
    for (final f in pages) {
      final ext = f.name.replaceAll('\\', '/').split('.').last.toLowerCase();
      final id = 'img${images.length + 1}';
      images.add(ExtractedImage(
          id: id, bytes: Uint8List.fromList(f.content), ext: ext));
      md.writeln('[[IMG:$id]]');
      md.writeln();
    }
    if (images.isEmpty) throw const FormatException('CBZ 内没有图片');
    return ExtractionWithImages(markdown: md.toString(), images: images);
  }

  static String extractAsMarkdown(List<int> bytes) =>
      extractPages(bytes).markdown;

  /// CBZ 无元数据（文件名即书名；可由 AI 补全）。
  static BookMetadata extractMetadata(List<int> bytes) =>
      const BookMetadata();
}
