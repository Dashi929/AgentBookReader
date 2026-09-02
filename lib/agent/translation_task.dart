import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:file_selector/file_selector.dart';

import '../infra/database.dart' hide Document;
import 'translation_providers.dart';
import 'workspace_tools.dart';

/// 单节译文（导出拼装用）。
class SectionTranslation {
  const SectionTranslation(this.title, this.content, {this.isHeading = false});
  final String title;
  final String content;

  /// md 文档的节标题应作为标题行输出；txt 的合成标题（"第 x 段"）不输出。
  final bool isHeading;
}

/// 把整篇译文拼装为 Markdown 文本（纯函数，可单测）。
String assembleTranslationMarkdown({
  required String docTitle,
  required String langName,
  required List<SectionTranslation> sections,
}) {
  final buf = StringBuffer('# ${docTitle.replaceAll('\n', ' ')} · $langName 译文\n\n');
  for (final s in sections) {
    if (s.isHeading && s.title.isNotEmpty) {
      buf
        ..writeln('## ${s.title.replaceAll('\n', ' ')}')
        ..writeln();
    }
    buf
      ..writeln(s.content)
      ..writeln();
  }
  return buf.toString().trimRight();
}

/// 整篇翻译任务：逐节调用翻译提供方，结果按 (docId, sectionIndex, lang)
/// 缓存进 Translations 表（重跑跳过已译节），完成后导出 Markdown 文件。
class WholeDocTranslationTask {
  WholeDocTranslationTask({
    required this.docs,
    required this.db,
    required this.provider,
    required this.targetLang,
  });

  final List<WorkspaceDoc> docs;
  final AppDatabase db;
  final TranslationProvider provider;
  final String targetLang;

  int get totalSections => docs.fold(
      0, (n, d) => n + d.controller.document.sections.length);

  /// 执行任务。[onProgress] 的 docTitle/sectionNo 为 1 基于当前文档的节序号。
  /// 返回 导出路径 → 译文文本 的映射。
  Future<Map<String, String>> run({
    required void Function(int done, int total, String docTitle) onProgress,
    required bool Function() cancelled,
  }) async {
    final exported = <String, String>{};
    var done = 0;

    for (final doc in docs) {
      final sections = <SectionTranslation>[];
      final isMd = doc.format == 'md';

      for (final section in doc.controller.document.sections) {
        if (cancelled()) return exported;
        onProgress(done, totalSections, doc.title);

        final raw = section.plainText.trim();
        // md 的节文本自带 "# 标题" 行：剥掉，标题统一由 isHeading 输出
        final text = isMd
            ? raw.split('\n').where((l) => !l.trimLeft().startsWith('#')).join('\n').trim()
            : raw;
        if (text.isEmpty) {
          sections.add(SectionTranslation(section.title, '', isHeading: isMd));
        } else {
          final cached = await _cached(doc.id, section.index);
          final content = cached ?? await provider.translate(text, targetLang: targetLang);
          if (!cancelled()) {
            await (db.into(db.translations).insertOnConflictUpdate(
                  TranslationsCompanion.insert(
                    docId: doc.id,
                    sectionIndex: section.index,
                    lang: targetLang,
                    content: content,
                    updatedAt: DateTime.now(),
                  ),
                ));
          }
          sections.add(SectionTranslation(section.title, content, isHeading: isMd));
        }
        done++;
      }

      if (cancelled()) return exported;
      final md = assembleTranslationMarkdown(
        docTitle: doc.title,
        langName: targetLang,
        sections: sections,
      );
      exported[await _exportPath(doc)] = md;
    }
    return exported;
  }

  Future<String?> _cached(String docId, int sectionIndex) async {
    final rows = await (db.select(db.translations)
          ..where((t) => t.docId.equals(docId) &
              t.sectionIndex.equals(sectionIndex) &
              t.lang.equals(targetLang)))
        .get();
    return rows.isEmpty ? null : rows.first.content;
  }

  /// 导出路径：与原文件同目录同名，扩展名替换为 `<lang>.md`。
  Future<String> _exportPath(WorkspaceDoc doc) async {
    final path = doc.path;
    if (path == null || path.isEmpty) {
      return '${doc.title}.$targetLang.md';
    }
    final dot = path.lastIndexOf('.');
    final stem = dot > 0 ? path.substring(0, dot) : path;
    return '$stem.$targetLang.md';
  }
}

/// 把译文写入本地文件（utf-8）。
Future<void> saveTranslationFile(String path, String content) async {
  await XFile.fromData(utf8.encode(content)).saveTo(path);
}
