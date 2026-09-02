import 'dart:typed_data';

/// 整行占位符：`[[IMG:imgN]]`（提取器为 docx/epub 内嵌图片生成）。
final RegExp imagePlaceholderRegex =
    RegExp(r'^\[\[IMG:([A-Za-z0-9_\-]+)\]\]$');

/// 从 docx/epub 提取出的内嵌图片：占位 id + 原始字节 + 扩展名。
class ExtractedImage {
  const ExtractedImage({
    required this.id,
    required this.bytes,
    required this.ext,
  });

  /// 占位符中的 id（如 img1），与 markdown 中的 [[IMG:imgN]] 对应。
  final String id;
  final Uint8List bytes;
  final String ext; // png / jpg / gif / webp / bmp
}

/// 提取结果：markdown 文本（含占位符）+ 按出现顺序的图片列表。
class ExtractionWithImages {
  const ExtractionWithImages({required this.markdown, required this.images});
  final String markdown;
  final List<ExtractedImage> images;
}
