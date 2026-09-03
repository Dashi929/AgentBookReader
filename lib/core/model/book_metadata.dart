import 'dart:typed_data';

/// 文档元数据（导入时提取；缺失部分可由 AI 补全）。
class BookMetadata {
  const BookMetadata({
    this.author = '',
    this.synopsis = '',
    this.coverBytes,
    this.coverExt = '',
  });

  final String author;
  final String synopsis;
  final Uint8List? coverBytes;
  final String coverExt; // png / jpg / ...

  bool get hasCover => coverBytes != null && coverBytes!.isNotEmpty;
}
