import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:xml/xml.dart';

import '../model/book_metadata.dart';
import '../model/extracted_image.dart';
import 'ooxml_core.dart';

/// .pptx 提取：ZIP → presentation.xml（sldIdLst 顺序）→ slides →
/// 每页 `# 标题`（占位符标题或"幻灯片 N"）+ 正文段落（a:p → 行），
/// 图片（a:blip → slide rels → ppt/media）转为 [[IMG:imgN]] 占位段。
class PptxExtractor {
  PptxExtractor._();

  static ArchiveFile? _find(Archive archive, String path) {
    final target = path.toLowerCase();
    for (final f in archive.files) {
      if (f.name.replaceAll('\\', '/').toLowerCase() == target) return f;
    }
    return null;
  }

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

  static String extractAsMarkdown(List<int> bytes) {
    return extractAsMarkdownWithImages(bytes).markdown;
  }

  static ExtractionWithImages extractAsMarkdownWithImages(List<int> bytes) {
    final archive = ZipDecoder().decodeBytes(bytes);
    final pres = _find(archive, 'ppt/presentation.xml');
    if (pres == null) {
      throw const FormatException('不是有效的 .pptx（缺少 ppt/presentation.xml）');
    }
    final rels = _presRels(archive);
    final doc =
        XmlDocument.parse(OoxmlCore.stripNs(utf8.decode(pres.content, allowMalformed: true)));
    final out = StringBuffer();
    final images = <ExtractedImage>[];
    var slideNo = 0;
    for (final sldId in doc.findAllElements('sldId')) {
      final rid =
          sldId.getAttribute('id', namespaceUri: _pptxRelNs) ?? sldId.getAttribute('r:id') ?? '';
      final target = rels[rid];
      if (target == null) continue;
      final f = _find(archive, _resolve('ppt/', target));
      if (f == null) continue;
      slideNo++;
      final slidePart = _resolve('ppt/', target); // 如 ppt/slides/slide1.xml
      final slideDoc =
          XmlDocument.parse(OoxmlCore.stripNs(utf8.decode(f.content, allowMalformed: true)));
      _writeSlide(
          slideDoc, slideNo, archive, slidePart, out, images);
    }
    if (slideNo == 0) out.writeln('（未找到幻灯片）');
    return ExtractionWithImages(markdown: out.toString(), images: images);
  }

  static String _dirOf(String partPath) {
    final i = partPath.lastIndexOf('/');
    return i == -1 ? '' : partPath.substring(0, i + 1);
  }

  static Map<String, String> _presRels(Archive archive) {
    final f = _find(archive, 'ppt/_rels/presentation.xml.rels');
    if (f == null) return const {};
    try {
      final doc =
          XmlDocument.parse(OoxmlCore.stripNs(utf8.decode(f.content, allowMalformed: true)));
      return {
        for (final r in doc.findAllElements('Relationship'))
          if ((r.getAttribute('Type') ?? '').endsWith('/slide'))
            r.getAttribute('Id')!: r.getAttribute('Target') ?? '',
      };
    } catch (_) {
      return const {};
    }
  }

  static void _writeSlide(XmlDocument doc, int slideNo, Archive archive,
      String slidePart, StringBuffer out, List<ExtractedImage> images) {
    final slideDir = _dirOf(slidePart); // 如 ppt/slides/
    final slideName = slidePart.substring(slidePart.lastIndexOf('/') + 1);
    final relsPath = '${slideDir}_rels/$slideName.rels';
    String? title;
    final bodyLines = <String>[];
    for (final sp in doc.findAllElements('sp')) {
      final ph = sp.findAllElements('ph').firstOrNull;
      final type = ph?.getAttribute('type');
      final isTitle = type == 'title' || type == 'ctrTitle';
      final texts = sp
          .findAllElements('p')
          .map((p) => p.findAllElements('t').map((t) => t.innerText).join())
          .where((l) => l.trim().isNotEmpty)
          .toList();
      if (isTitle && title == null && texts.isNotEmpty) {
        title = texts.first;
      } else {
        bodyLines.addAll(texts);
      }
    }
    out.writeln('# ${title ?? '幻灯片 $slideNo'}');
    out.writeln();
    for (final line in bodyLines) {
      out.writeln(line);
      out.writeln();
    }
    // 图片：a:blip r:embed → slide rels → ppt/media
    for (final blip in doc.findAllElements('blip')) {
      final rid =
          blip.getAttribute('embed', namespaceUri: _pptxRelNs) ?? blip.getAttribute('r:embed') ?? '';
      if (rid.isEmpty) continue;
      final mediaPath = _imageTarget(archive, relsPath, rid);
      if (mediaPath == null) continue;
      final f = _find(archive, mediaPath);
      if (f == null) continue;
      final ext = mediaPath.split('.').last.toLowerCase();
      final id = 'img${images.length + 1}';
      images.add(ExtractedImage(
          id: id, bytes: Uint8List.fromList(f.content), ext: ext));
      out.writeln('[[IMG:$id]]');
      out.writeln();
    }
  }

  /// slide rels：rId → 图片部件绝对路径。
  static String? _imageTarget(
      Archive archive, String relsPath, String rid) {
    final f = _find(archive, relsPath);
    if (f == null) return null;
    try {
      final doc =
          XmlDocument.parse(OoxmlCore.stripNs(utf8.decode(f.content, allowMalformed: true)));
      for (final r in doc.findAllElements('Relationship')) {
        if (r.getAttribute('Id') == rid &&
            (r.getAttribute('Type') ?? '').endsWith('/image')) {
          final dir =
              relsPath.substring(0, relsPath.indexOf('_rels/'));
          return _resolve(dir, r.getAttribute('Target') ?? '');
        }
      }
    } catch (_) {}
    return null;
  }

  /// 元数据：docProps/core.xml。
  static BookMetadata extractMetadata(List<int> bytes) =>
      OoxmlCore.extract(bytes);
}

//================ 结构化解析（供幻灯片画布渲染，Office 视觉近似） ================

final String _bs = String.fromCharCode(92);

const String _pptxRelNs =
    'http://schemas.openxmlformats.org/officeDocument/2006/relationships';

String _dirOfPart(String partPath) {
  final i = partPath.lastIndexOf('/');
  return i == -1 ? '' : partPath.substring(0, i + 1);
}

/// 一个文本段落（样式取自首个 run 的 rPr）。
class PptPara {
  PptPara(this.text, this.sizePt, this.bold, this.color, this.align);
  final String text;
  final double? sizePt; // rPr sz / 100
  final bool bold;
  final int? color; // srgbClr RRGGBB
  final String align; // l | ctr | r
}

/// 文本框：xfrm 位置（EMU）；hasPos=false 时无位置信息（回退线性布局）。
class PptTextBox {
  PptTextBox(this.hasPos, this.x, this.y, this.w, this.h, this.paras);
  final bool hasPos;
  final double x, y, w, h;
  final List<PptPara> paras;
}

class PptImageData {
  PptImageData(this.x, this.y, this.w, this.h, this.bytes);
  final double x, y, w, h;
  final Uint8List bytes;
}

class PptSlideData {
  PptSlideData(this.wEmu, this.hEmu, this.title, this.boxes, this.images);
  final double wEmu, hEmu;
  final String? title;
  final List<PptTextBox> boxes;
  final List<PptImageData> images;
}

/// 解析每页形状位置/文本样式/图片（表格、图表等复杂对象不渲染）。
List<PptSlideData> parsePptxSlides(List<int> bytes) {
  final archive = ZipDecoder().decodeBytes(bytes);
  ArchiveFile? find(String path) {
    final t = path.toLowerCase();
    for (final f in archive.files) {
      if (f.name.replaceAll(r'\', '/').toLowerCase() == t) return f;
    }
    return null;
  }

  final pres = find('ppt/presentation.xml');
  if (pres == null) {
    throw const FormatException('不是有效的 .pptx（缺少 ppt/presentation.xml）');
  }
  final presDoc = XmlDocument.parse(
      OoxmlCore.stripNs(utf8.decode(pres.content, allowMalformed: true)));
  double wEmu = double.tryParse(
          presDoc.findAllElements('sldSz').firstOrNull?.getAttribute('cx') ??
              '') ??
      12192000;
  double hEmu = double.tryParse(
          presDoc.findAllElements('sldSz').firstOrNull?.getAttribute('cy') ??
              '') ??
      6858000;

  // presentation rels
  final relMap = <String, String>{};
  final relsFile = find('ppt/_rels/presentation.xml.rels');
  if (relsFile != null) {
    final rels = XmlDocument.parse(OoxmlCore.stripNs(
        utf8.decode(relsFile.content, allowMalformed: true)));
    for (final r in rels.findAllElements('Relationship')) {
      if ((r.getAttribute('Type') ?? '').endsWith('/slide')) {
        relMap[r.getAttribute('Id')!] = r.getAttribute('Target') ?? '';
      }
    }
  }

  final slides = <PptSlideData>[];
  for (final sldId in presDoc.findAllElements('sldId')) {
    final rid =
        sldId.getAttribute('id', namespaceUri: _pptxRelNs) ?? sldId.getAttribute('r:id') ?? '';
    final target = relMap[rid];
    if (target == null) continue;
    final part = _resolvePptPath('ppt/', target);
    final f = find(part);
    if (f == null) continue;
    final doc = XmlDocument.parse(
        OoxmlCore.stripNs(utf8.decode(f.content, allowMalformed: true)));
    final slideDir = _dirOfPart(part);
    final slideName = part.substring(part.lastIndexOf('/') + 1);

    final boxes = <PptTextBox>[];
    final images = <PptImageData>[];
    String? title;
    for (final sp in doc.findAllElements('sp')) {
      final ph = sp.findAllElements('ph').firstOrNull;
      final isTitle =
          (ph?.getAttribute('type') ?? '') == 'title' ||
              (ph?.getAttribute('type') ?? '') == 'ctrTitle';
      final paras = <PptPara>[];
      for (final p in sp.findAllElements('p')) {
        final runs = p.findAllElements('r');
        if (runs.isEmpty) continue;
        final buf = StringBuffer();
        double? sz;
        bool bold = false;
        int? color;
        for (final r in runs) {
          buf.write(r.findAllElements('t').map((t) => t.innerText).join());
          final rPr = r.findAllElements('rPr').firstOrNull;
          sz ??= double.tryParse(rPr?.getAttribute('sz') ?? '');
          bold = bold || (rPr?.getAttribute('b') == '1');
          color ??= int.tryParse(
              '0x${rPr?.findAllElements('srgbClr').firstOrNull?.getAttribute('val') ?? ''}',
              radix: 16);
        }
        if (buf.toString().trim().isEmpty) continue;
        paras.add(PptPara(
            buf.toString(),
            sz == null ? null : sz / 100,
            bold,
            color,
            p.findAllElements('pPr').firstOrNull?.getAttribute('algn') ?? 'l'));
      }
      if (paras.isEmpty) continue;
      if (isTitle && title == null) title = paras.first.text;
      // xfrm
      final off =
          sp.findAllElements('off').firstOrNull; // a:off（stripNs 后无前缀）
      final ext = sp.findAllElements('ext').firstOrNull;
      if (off == null || ext == null) {
        boxes.add(PptTextBox(false, 0, 0, 0, 0, paras));
        continue;
      }
      boxes.add(PptTextBox(
          true,
          double.parse(off.getAttribute('x') ?? '0'),
          double.parse(off.getAttribute('y') ?? '0'),
          double.parse(ext.getAttribute('cx') ?? '0'),
          double.parse(ext.getAttribute('cy') ?? '0'),
          paras));
    }
    // 图片
    final relsPath = '${slideDir}_rels/$slideName.rels';
    for (final pic in doc.findAllElements('pic')) {
      final blip = pic.findAllElements('blip').firstOrNull;
      if (blip == null) continue;
      final rId = blip.getAttribute('embed', namespaceUri: _pptxRelNs) ??
          blip.getAttribute('r:embed') ??
          '';
      final media = _imageTargetFrom(archive, relsPath, rId);
      if (media == null) continue;
      final off = pic.findAllElements('off').firstOrNull;
      final ext = pic.findAllElements('ext').firstOrNull;
      images.add(PptImageData(
          double.parse(off?.getAttribute('x') ?? '0'),
          double.parse(off?.getAttribute('y') ?? '0'),
          double.parse(ext?.getAttribute('cx') ?? wEmu.toString()),
          double.parse(ext?.getAttribute('cy') ?? hEmu.toString()),
          media));
    }
    slides.add(PptSlideData(wEmu, hEmu, title, boxes, images));
  }
  return slides;
}

String _resolvePptPath(String baseDir, String target) {
  var t = target.replaceAll(r'\', '/');
  var base = baseDir;
  while (t.startsWith('../')) {
    base = base.substring(0, base.lastIndexOf('/', base.length - 2) + 1);
    t = t.substring(3);
  }
  if (t.startsWith('/')) return t.substring(1);
  return '$base$t';
}

/// slide rels：rId → 图片字节（找不到返回 null）。
Uint8List? _imageTargetFrom(Archive archive, String relsPath, String rid) {
  final i = relsPath.toLowerCase().indexOf('_rels/');
  if (i == -1 || rid.isEmpty) return null;
  final dir = relsPath.substring(0, i);
  for (final f in archive.files) {
    if (f.name.replaceAll(_bs, '/').toLowerCase() != relsPath.toLowerCase()) {
      continue;
    }
    final doc = XmlDocument.parse(
        OoxmlCore.stripNs(utf8.decode(f.content, allowMalformed: true)));
    for (final r in doc.findAllElements('Relationship')) {
      if (r.getAttribute('Id') == rid &&
          (r.getAttribute('Type') ?? '').endsWith('/image')) {
        final path = _resolvePptPath(dir, r.getAttribute('Target') ?? '');
        for (final m in archive.files) {
          if (m.name.replaceAll(_bs, '/').toLowerCase() == path.toLowerCase()) {
            return Uint8List.fromList(m.content);
          }
        }
      }
    }
  }
  return null;
}
