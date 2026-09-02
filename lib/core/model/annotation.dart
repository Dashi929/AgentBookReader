import 'char_range.dart';

class Annotation {
  const Annotation({
    required this.id,
    required this.docId,
    required this.range,
    required this.kind,
    required this.originalText,
    required this.content,
    required this.createdAt,
  });

  final String id;
  final String docId;
  final CharRange range;
  final AnnotationKind kind;

  /// 原文片段（改写前快照）。
  final String originalText;
  final String content;
  final DateTime createdAt;
}

class DocTextEdit {
  const DocTextEdit.replace(this.range, this.newText) : isDeletion = false;
  const DocTextEdit.delete(this.range)
      : newText = '',
        isDeletion = true;

  final CharRange range;
  final String newText;
  final bool isDeletion;
}

class SearchHit {
  const SearchHit(this.range, this.sectionIndex, this.preview);
  final CharRange range;
  final int sectionIndex;
  final String preview;
}
