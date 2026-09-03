import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/io/text_decoder.dart';
import '../core/model/extracted_image.dart';
import '../core/parser/docx_extractor.dart';
import '../core/parser/epub_extractor.dart';
import '../l10n/app_localizations.dart';
import 'package:path_provider/path_provider.dart';
import '../state/app_state.dart';
import 'agent_settings_screen.dart';
import 'agent_workspace_page.dart';
import 'reader_screen.dart';

/// 书架：列表 + 批量导入（txt/md/json/docx）+ 打开。
class LibraryPage extends ConsumerWidget {
  const LibraryPage({super.key});

  static const _allowedExt = {'txt', 'md', 'json', 'docx', 'epub', 'pdf'};

  Future<void> _import(BuildContext context, WidgetRef ref) async {
    final s = AppLocalizations.of(context)!;
    // 不按扩展名过滤选择器：真机 ROM 的 SAF 对 MIME/扩展名映射不一致，
    // 过滤后目标文件可能全部置灰或直接报权限错误；改为应用内按扩展名校验。
    const typeGroup = XTypeGroup(label: 'documents');
    List<XFile> files;
    try {
      files = await openFiles(acceptedTypeGroups: [typeGroup]);
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(s.importFailed(e.toString()))));
      }
      return;
    }
    if (files.isEmpty) return;

    final opened = <({String title, String format, String content, String entryId})>[];
    final errors = <String>[];
    for (final file in files) {
      final ext = file.name.split('.').last.toLowerCase();
      if (!_allowedExt.contains(ext)) {
        errors.add('${file.name}: unsupported type');
        continue;
      }
      try {
        final entryId = '${DateTime.now().microsecondsSinceEpoch}_${file.name}';
        final rawBytes = await file.readAsBytes();
        // 复制进应用私有目录并存该路径：file_selector 在 Android 返回的是
        // SAF 临时缓存路径，系统清理缓存后重开/写回会失败。
        final supportDir = await getApplicationSupportDirectory();
        final persisted = File('${supportDir.path}/imported/$entryId.$ext');
        await persisted.create(recursive: true);
        await persisted.writeAsBytes(rawBytes, flush: true);
        // pdf：不经文本管道，阅读器用 pdfium 渲染页面；
        // docx/epub：提取为 Markdown（标题→#）+ 内嵌图片占位段
        String format;
        String content;
        var extractedImages = const <ExtractedImage>[];
        if (ext == 'pdf') {
          format = 'pdf';
          content = '';
        } else if (ext == 'docx') {
          final r = DocxExtractor.extractAsMarkdownWithImages(rawBytes);
          format = 'md';
          content = r.markdown;
          extractedImages = r.images;
        } else if (ext == 'epub') {
          final r = EpubExtractor.extractAsMarkdownWithImages(rawBytes);
          format = 'md';
          content = r.markdown;
          extractedImages = r.images;
        } else {
          format = ext;
          content = TextDecoder.decode(rawBytes);
        }
        final entry = BookEntry(
          id: entryId,
          title: file.name,
          path: persisted.path,
          extension: ext,
        );
        if (extractedImages.isNotEmpty) {
          await _saveImages(entryId, extractedImages);
        }
        await ref.read(libraryProvider.notifier).add(entry);
        opened.add((
          title: file.name,
          format: format,
          content: content,
          entryId: entry.id,
        ));
      } catch (e) {
        // 单个文件失败不阻断批量导入，但错误要可见（否则表现为"没反应"）
        errors.add('${file.name}: $e');
      }
    }

    if (context.mounted) {
      if (opened.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(
                s.importFailed(errors.isEmpty ? 'no valid files' : errors.join('; ')))));
        return;
      }
      if (errors.isNotEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(s.importFailed(errors.join('; ')))));
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

  /// 内嵌图片落盘：`images/<entryId>/imgN.<ext>` + manifest.json（宽高信息）。
  static Future<void> _saveImages(
      String entryId, List<ExtractedImage> images) async {
    try {
      final support = await getApplicationSupportDirectory();
      final imgDir = Directory('${support.path}/images/$entryId');
      await imgDir.create(recursive: true);
      final manifest = <String, Map<String, dynamic>>{};
      for (final img in images) {
        final f = File('${imgDir.path}/${img.id}.${img.ext}');
        await f.writeAsBytes(img.bytes);
        final (w, h) = _imageSize(img.bytes, img.ext);
        manifest[img.id] = {'file': '${img.id}.${img.ext}', 'w': w, 'h': h};
      }
      await File('${imgDir.path}/manifest.json')
          .writeAsString(jsonEncode(manifest), flush: true);
    } catch (_) {
      // 图片保存失败不阻断导入（阅读时仅显示占位文本）
    }
  }

 /// 解析图片文件头获取宽高（PNG/JPEG/GIF/BMP）；失败返回 (0,0)。
 static (int, int) _imageSize(Uint8List bytes, String ext) {
   try {
     if (ext == 'png' && bytes.length > 24) {
       final w = (bytes[16] << 24) | (bytes[17] << 16) | (bytes[18] << 8) | bytes[19];
       final h = (bytes[20] << 24) | (bytes[21] << 16) | (bytes[22] << 8) | bytes[23];
       return (w, h);
     }
     if (ext == 'gif' && bytes.length > 10) {
       return (bytes[6] | (bytes[7] << 8), bytes[8] | (bytes[9] << 8));
     }
     if (ext == 'bmp' && bytes.length > 26) {
       final w = bytes[18] | (bytes[19] << 8) | (bytes[20] << 16) | (bytes[21] << 24);
       final h = bytes[22] | (bytes[23] << 8) | (bytes[24] << 16) | (bytes[25] << 24);
       return (w, h.abs());
     }
     if ((ext == 'jpg' || ext == 'jpeg') && bytes.length > 9) {
       var i = 2;
       while (i + 9 < bytes.length) {
         if (bytes[i] != 0xFF) {
           i++;
           continue;
         }
         final marker = bytes[i + 1];
         if (marker >= 0xC0 && marker <= 0xCF && marker != 0xC4 && marker != 0xC8 && marker != 0xCC) {
           final h = (bytes[i + 5] << 8) | bytes[i + 6];
           final w = (bytes[i + 7] << 8) | bytes[i + 8];
           return (w, h);
         }
         final len = (bytes[i + 2] << 8) | bytes[i + 3];
         i += 2 + len;
       }
     }
   } catch (_) {}
   return (0, 0);
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
