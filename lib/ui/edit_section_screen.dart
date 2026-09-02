import 'dart:convert';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

import '../core/controller/document_controller.dart';
import '../core/model/annotation.dart';
import '../core/model/char_range.dart';
import '../core/model/document.dart';
import '../l10n/app_localizations.dart';

/// 编辑当前节：文本框修改 → applyEdit（重解析）→ 可导出/写回原文件。
class EditSectionScreen extends StatefulWidget {
  const EditSectionScreen({
    super.key,
    required this.controller,
    required this.sectionIndex,
    required this.filePath,
    required this.format,
  });

  final DocumentController controller;
  final int sectionIndex;
  final String? filePath; // 有原文件才允许"写回原文件"
  final String format;

  @override
  State<EditSectionScreen> createState() => _EditSectionScreenState();
}

class _EditSectionScreenState extends State<EditSectionScreen> {
  late final TextEditingController _text;
  late final Section? _section;

  @override
  void initState() {
    super.initState();
    _section = widget.controller.sectionAt(widget.sectionIndex);
    _text = TextEditingController(text: _section?.plainText ?? '');
  }

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  Future<void> _applyEdit() async {
    final s = AppLocalizations.of(context)!;
    if (_section == null) return;
    await widget.controller.applyEdit(DocTextEdit.replace(
      CharRange(_section.charOffset, _section.charOffset + _section.charCount),
      '${_text.text}\n\n',
    ));

    // txt/md/json：自动写回原文件（先备份 .bak）；docx：仅保存在应用内
    if (widget.filePath != null && widget.format != 'docx') {
      final bytes = await XFile(widget.filePath!).readAsBytes();
      await XFile.fromData(bytes).saveTo('${widget.filePath}.bak');
      final out = widget.format == 'json'
          ? jsonEncode(widget.controller.document.sections
              .map((sec) => {
                    'index': sec.index,
                    'title': sec.title,
                    'text': sec.plainText,
                  })
              .toList())
          : widget.controller.rawText;
      await XFile.fromData(utf8.encode(out)).saveTo(widget.filePath!);
    }

    if (mounted) {
      final note = widget.format == 'docx' ? '（docx 编辑仅保存在应用内，可导出）' : '（原文件已备份并更新）';
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('${s.confirm}$note')));
      Navigator.pop(context);
    }
  }

  Future<void> _exportOrSave({required bool exportAs}) async {
    final s = AppLocalizations.of(context)!;
    String? targetPath = widget.filePath;
    if (exportAs || targetPath == null || widget.format == 'docx') {
      final ext = widget.format == 'docx' ? 'txt' : widget.format;
      final location = await getSaveLocation(
          suggestedName:
              '${widget.controller.document.title}.$ext');
      if (location == null) return;
      targetPath = location.path;
    } else {
      // 写回原文件前备份 .bak
      final bytes = await XFile(targetPath).readAsBytes();
      await XFile.fromData(bytes).saveTo('$targetPath.bak');
    }
    final out = newExt(targetPath) == 'json'
        ? jsonEncode(widget.controller.document.sections
            .map((sec) => {
                  'index': sec.index,
                  'title': sec.title,
                  'text': sec.plainText,
                })
            .toList())
        : widget.controller.rawText;
    await XFile.fromData(utf8.encode(out)).saveTo(targetPath);
    if (mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('${s.confirm}: $targetPath')));
    }
  }

  static String newExt(String path) => path.split('.').last.toLowerCase();

  @override
  Widget build(BuildContext context) {
    final s = AppLocalizations.of(context)!;
    return Scaffold(
      appBar: AppBar(
        title: Text('${s.reader} · ${s.section(widget.sectionIndex + 1)}'),
        actions: [
          IconButton(
            icon: const Icon(Icons.save_outlined),
            tooltip: s.confirm,
            onPressed: _applyEdit,
          ),
          IconButton(
            icon: const Icon(Icons.file_download_outlined),
            tooltip: '导出',
            onPressed: () => _exportOrSave(exportAs: true),
          ),
          if (widget.filePath != null && widget.format != 'docx')
            IconButton(
              icon: const Icon(Icons.drive_file_move_outline),
              tooltip: '写入原文件(.bak)',
              onPressed: () => _exportOrSave(exportAs: false),
            ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(12),
        child: TextField(
          controller: _text,
          maxLines: null,
          expands: true,
          textAlignVertical: TextAlignVertical.top,
          decoration: const InputDecoration(
              border: OutlineInputBorder(), isDense: true),
        ),
      ),
    );
  }
}
