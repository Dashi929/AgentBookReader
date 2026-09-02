import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/io/text_decoder.dart';
import '../core/parser/docx_extractor.dart';
import '../core/parser/epub_extractor.dart';
import '../l10n/app_localizations.dart';
import '../state/app_state.dart';
import 'agent_settings_screen.dart';
import 'agent_workspace_page.dart';
import 'reader_screen.dart';

/// 书架：列表 + 批量导入（txt/md/json/docx）+ 打开。
class LibraryPage extends ConsumerWidget {
  const LibraryPage({super.key});

  static const _allowedExt = {'txt', 'md', 'json', 'docx', 'epub'};

  Future<void> _import(BuildContext context, WidgetRef ref) async {
    final s = AppLocalizations.of(context)!;
    const typeGroup = XTypeGroup(
      label: 'documents',
      extensions: ['txt', 'md', 'json', 'docx', 'epub'],
    );
    final files = await openFiles(acceptedTypeGroups: [typeGroup]);
    if (files.isEmpty) return;

    final opened = <({String title, String format, String content, String entryId})>[];
    for (final file in files) {
      final ext = file.name.split('.').last.toLowerCase();
      if (!_allowedExt.contains(ext)) continue;
      try {
        final bytes = await file.readAsBytes();
        // docx/epub：提取为 Markdown（标题→#），阅读器按 md 处理
        final (format, content) = ext == 'docx'
            ? ('md', DocxExtractor.extractAsMarkdown(bytes))
            : ext == 'epub'
                ? ('md', EpubExtractor.extractAsMarkdown(bytes))
                : (ext, TextDecoder.decode(bytes));
        final entry = BookEntry(
          id: '${DateTime.now().microsecondsSinceEpoch}_${file.name}',
          title: file.name,
          path: file.path,
          extension: ext,
        );
        await ref.read(libraryProvider.notifier).add(entry);
        opened.add((
          title: file.name,
          format: format,
          content: content,
          entryId: entry.id,
        ));
      } catch (_) {
        // 单个文件失败不阻断批量导入
      }
    }

    if (context.mounted) {
      if (opened.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(s.importFailed('no valid files'))));
        return;
      }
      final first = opened.first;
      Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => ReaderScreen(
          title: first.title,
          format: first.format,
          initialContent: first.content,
          entryId: first.entryId,
        ),
      ));
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = AppLocalizations.of(context)!;
    final books = ref.watch(libraryProvider);
    return Scaffold(
      appBar: AppBar(title: Text(s.appTitle), actions: [
        IconButton(
          icon: const Icon(Icons.smart_toy_outlined),
          tooltip: '${s.agentPanel} · ${s.library}',
          onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const AgentWorkspacePage())),
        ),
        IconButton(
          icon: const Icon(Icons.settings_outlined),
          tooltip: '${s.settings} · ${s.agentPanel}',
          onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const AgentSettingsScreen())),
        ),
      ]),
      body: books.isEmpty
          ? Center(child: Text(s.importFiles))
          : ListView.builder(
              itemCount: books.length,
              itemBuilder: (context, i) {
                final b = books[i];
                return ListTile(
                  leading: Text(b.extension.toUpperCase(),
                      style: const TextStyle(
                          fontWeight: FontWeight.bold, color: Colors.teal)),
                  title: Text(b.title, overflow: TextOverflow.ellipsis),
                  subtitle: b.lastPage > 0 ? Text(s.page(b.lastPage + 1)) : null,
                  trailing: IconButton(
                    icon: const Icon(Icons.delete_outline),
                    onPressed: () =>
                        ref.read(libraryProvider.notifier).remove(b.id),
                  ),
                  onTap: () async {
                    String content = '';
                    var format = b.extension;
                    try {
                      final bytes = await XFile(b.path).readAsBytes();
                      if (b.extension == 'docx') {
                        format = 'md';
                        content = DocxExtractor.extractAsMarkdown(bytes);
                      } else if (b.extension == 'epub') {
                        format = 'md';
                        content = EpubExtractor.extractAsMarkdown(bytes);
                      } else {
                        content = TextDecoder.decode(bytes);
                      }
                    } catch (_) {}
                    if (context.mounted) {
                      Navigator.of(context).push(MaterialPageRoute(
                        builder: (_) => ReaderScreen(
                          title: b.title,
                          format: format,
                          initialContent: content,
                          entryId: b.id,
                          initialPage: b.lastPage,
                        ),
                      ));
                    }
                  },
                );
              },
            ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _import(context, ref),
        icon: const Icon(Icons.upload_file),
        label: Text(s.importFiles),
      ),
    );
  }
}
