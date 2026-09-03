import 'dart:convert';
import 'dart:io';

import 'package:file_selector/file_selector.dart' show XFile;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pdfrx/pdfrx.dart';

import '../agent/agent_settings.dart';
import '../agent/llm_client.dart';
import '../core/controller/plain_text_document.dart';
import '../core/model/char_range.dart' show DocFormat;
import '../core/parser/docx_extractor.dart';
import '../core/parser/epub_extractor.dart';
import '../core/io/text_decoder.dart';
import '../l10n/app_localizations.dart';
import '../state/app_state.dart';
import 'agent_workspace_page.dart';
import 'reader_screen.dart';

/// 图书详情页：封面/书名/作者/简介/章节/进度/预览，
/// 可开始阅读、调用 Agent 工作台；缺失元数据可由 AI 补全。
class BookDetailScreen extends ConsumerStatefulWidget {
  const BookDetailScreen({super.key, required this.entryId});

  final String entryId;

  @override
  ConsumerState<BookDetailScreen> createState() => _BookDetailScreenState();
}

class _BookDetailScreenState extends ConsumerState<BookDetailScreen> {
  List<({String title, String? subtitle})> _chapters = const [];
  String _preview = '';
  String _content = ''; // 非 PDF：已解码全文，供开始阅读复用
  bool _loading = true;
  bool _completing = false;
  String? _error;

  BookEntry? get _entry => ref.read(libraryProvider.notifier).byId(widget.entryId);

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final entry = _entry;
    if (entry == null) {
      setState(() {
        _loading = false;
        _error = '条目不存在';
      });
      return;
    }
    try {
      final bytes = await XFile(entry.path).readAsBytes();
      final ext = entry.extension;
      if (ext == 'pdf') {
        final pdf = await PdfDocument.openData(bytes);
        // 章节：书签；无书签则不列（逐页列表意义不大，阅读器内可跳页）
        final chapters = <({String title, String? subtitle})>[];
        void walk(List<PdfOutlineNode> nodes, int depth) {
          for (final n in nodes) {
            final page = n.dest?.pageNumber;
            if (n.title.trim().isNotEmpty) {
              chapters.add((
                title: '  ' * depth + n.title.trim(),
                subtitle: page == null ? null : '第 $page 页',
              ));
            }
            walk(n.children, depth + 1);
          }
        }

        walk(await pdf.loadOutline(), 0);
        String preview = '';
        for (final p in pdf.pages) {
          final t = (await p.loadText())?.fullText.trim() ?? '';
          if (t.isNotEmpty) {
            preview = t;
            break;
          }
        }
        pdf.dispose();
        if (mounted) {
          setState(() {
            _chapters = chapters;
            _preview =
                preview.isEmpty ? '' : (preview.length > 300 ? '${preview.substring(0, 300)}…' : preview);
            _loading = false;
          });
        }
        return;
      }
      final content = switch (ext) {
        'docx' => DocxExtractor.extractAsMarkdown(bytes),
        'epub' => EpubExtractor.extractAsMarkdown(bytes),
        _ => TextDecoder.decode(bytes),
      };
      _content = content;
      final format = switch (ext) {
        'md' || 'docx' || 'epub' => DocFormat.md,
        'json' => DocFormat.json,
        _ => DocFormat.txt,
      };
      final doc = await PlainTextDocument.create(
          entry.id, entry.title, format, content);
      final chapters = <({String title, String? subtitle})>[];
      for (final sec in doc.document.sections) {
        final title = sec.title.trim();
        if (doc.document.sections.length > 1 || title.isNotEmpty) {
          chapters.add((
            title: title.isEmpty ? '第 ${sec.index + 1} 节' : title,
            subtitle: '${sec.paragraphs.length} 段',
          ));
        }
      }
      final previewText = doc.document.sections
          .expand((s) => s.paragraphs)
          .map((p) => p.plainText)
          .where((t) => t.trim().isNotEmpty && !t.startsWith('[[IMG:'))
          .join('\n');
      if (mounted) {
        setState(() {
          _chapters = chapters;
          _preview = previewText.isEmpty
              ? ''
              : (previewText.length > 300
                  ? '${previewText.substring(0, 300)}…'
                  : previewText);
          _loading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = '$e';
        });
      }
    }
  }

  /// AI 补全：让 LLM 从文件名 + 内容开头推断作者与简介，返回 JSON。
  Future<void> _aiComplete() async {
    final entry = _entry;
    if (entry == null || _completing) return;
    final s = AppLocalizations.of(context)!;
    final settings = await AgentSettings.instance.read();
    if (settings.baseUrl.isEmpty || settings.model.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('请先在设置中配置 LLM 接口')));
      }
      return;
    }
    setState(() => _completing = true);
    try {
      final excerpt = _preview.isEmpty ? '' : _preview.substring(0, _preview.length.clamp(0, 600));
      final client = LlmClient(
          baseUrl: settings.baseUrl,
          apiKey: settings.apiKey,
          model: settings.model);
      final resp = await client.chat(messages: [
        LlmMessage.system('你是图书元数据助手。只输出一个 JSON 对象，'
            '格式：{"author": "作者名，推断不出则为空字符串", '
            '"synopsis": "50-150字的简介（用与书籍相同的语言）"}，不要输出其他内容。'),
        LlmMessage.user('文件名：${entry.title}\n\n内容开头：\n$excerpt'),
      ]);
      final json = _extractJson(resp.content ?? '');
      final author = (json['author'] as String?)?.trim() ?? '';
      final synopsis = (json['synopsis'] as String?)?.trim() ?? '';
      await ref
          .read(libraryProvider.notifier)
          .updateMeta(entry.id, author: author, synopsis: synopsis);
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(s.aiCompleteDone)));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('${s.aiComplete}失败: $e')));
      }
    } finally {
      if (mounted) setState(() => _completing = false);
    }
  }

  static Map<String, dynamic> _extractJson(String text) {
    final m = RegExp(r'\{[\s\S]*\}').firstMatch(text);
    if (m == null) return {};
    try {
      return jsonDecode(m.group(0)!) as Map<String, dynamic>;
    } catch (_) {
      return {};
    }
  }

  void _startReading() {
    final entry = _entry;
    if (entry == null) return;
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => ReaderScreen(
        title: entry.title,
        format: entry.extension,
        // PDF 走阅读器的原版渲染模式，initialContent 不使用
        initialContent: _content,
        entryId: entry.id,
        initialPage: entry.lastPage,
      ),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final s = AppLocalizations.of(context)!;
    ref.watch(libraryProvider); // 元数据更新后刷新
    final entry = _entry;
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(s.bookDetail), actions: [
        IconButton(
          tooltip: s.agentPanel,
          icon: const Icon(Icons.smart_toy_outlined),
          onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const AgentWorkspacePage())),
        ),
      ]),
      body: entry == null
          ? Center(child: Text(_error ?? '…'))
          : _loading && _chapters.isEmpty && _preview.isEmpty
              ? const Center(child: CircularProgressIndicator())
              : ListView(
                  padding: const EdgeInsets.all(16),
                  children: [
                    Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      SizedBox(
                        width: 120,
                        height: 180, // Row 纵向无界，封面必须显式限高
                        child: BookCover(entry: entry, borderRadius: 8),
                      ),
                      const SizedBox(width: 16),
                      Expanded(
                        child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(entry.title,
                                  style: const TextStyle(
                                      fontSize: 20,
                                      fontWeight: FontWeight.bold)),
                              const SizedBox(height: 8),
                              Row(children: [
                                Text('${s.author}：',
                                    style: TextStyle(
                                        fontSize: 14,
                                        color:
                                            theme.colorScheme.onSurfaceVariant)),
                                Expanded(
                                  child: Text(
                                      entry.author.isEmpty
                                          ? s.unknownAuthor
                                          : entry.author,
                                      style: TextStyle(
                                          fontSize: 14,
                                          color: entry.author.isEmpty
                                              ? theme.colorScheme.onSurfaceVariant
                                                  .withValues(alpha: 0.6)
                                              : null)),
                                ),
                              ]),
                              const SizedBox(height: 4),
                              Text(
                                  '${entry.extension.toUpperCase()} · ${entry.lastPage > 0 ? s.page(entry.lastPage + 1) : s.preview}',
                                  style: TextStyle(
                                      fontSize: 13,
                                      color:
                                          theme.colorScheme.onSurfaceVariant)),
                            ]),
                      ),
                    ]),
                    const SizedBox(height: 20),
                    _SectionTitle(s.synopsis),
                    Text(
                        entry.synopsis.isEmpty
                            ? s.noSynopsis
                            : entry.synopsis,
                        style: TextStyle(
                            fontSize: 14,
                            height: 1.6,
                            color: entry.synopsis.isEmpty
                                ? theme.colorScheme.onSurfaceVariant
                                : null)),
                    const SizedBox(height: 20),
                    FilledButton.icon(
                      onPressed: _completing ? null : _aiComplete,
                      icon: _completing
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child:
                                  CircularProgressIndicator(strokeWidth: 2))
                          : const Icon(Icons.auto_fix_high_outlined),
                      label: Text(s.aiComplete),
                    ),
                    if (_preview.isNotEmpty) ...[
                      const SizedBox(height: 20),
                      _SectionTitle(s.preview),
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: theme.colorScheme.surfaceContainerHighest
                              .withValues(alpha: 0.4),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Text(_preview,
                            style: const TextStyle(
                                fontSize: 13, height: 1.7)),
                      ),
                    ],
                    if (_chapters.isNotEmpty) ...[
                      const SizedBox(height: 20),
                      _SectionTitle(s.chapters),
                      ..._chapters.map((c) => ListTile(
                            dense: true,
                            contentPadding: EdgeInsets.zero,
                            leading: const Icon(Icons.article_outlined,
                                size: 18),
                            title: Text(c.title, maxLines: 1),
                            subtitle: c.subtitle == null
                                ? null
                                : Text(c.subtitle!),
                          )),
                    ],
                    const SizedBox(height: 24),
                    FilledButton.icon(
                      onPressed: _startReading,
                      icon: const Icon(Icons.menu_book_outlined),
                      label: Text(s.startReading),
                    ),
                    const SizedBox(height: 8),
                    OutlinedButton.icon(
                      onPressed: () => Navigator.of(context).push(
                          MaterialPageRoute(
                              builder: (_) => const AgentWorkspacePage())),
                      icon: const Icon(Icons.smart_toy_outlined),
                      label: Text(s.agentPanel),
                    ),
                    const SizedBox(height: 32),
                  ],
                ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Text(text,
          style: const TextStyle(
              fontSize: 15, fontWeight: FontWeight.w700, color: Colors.teal)),
    );
  }
}

/// 封面组件：有封面图用图，否则按书名生成占位封面（首字 + 稳定配色）。
class BookCover extends StatelessWidget {
  const BookCover({super.key, required this.entry, this.borderRadius = 10});

  final BookEntry entry;
  final double borderRadius;

  static const _palette = [
    Color(0xFF2E7D72),
    Color(0xFF5B6ABF),
    Color(0xFF8C6A4F),
    Color(0xFF7A5C9E),
    Color(0xFF3F7CA6),
    Color(0xFFA66A5C),
  ];

  @override
  Widget build(BuildContext context) {
    final r = BorderRadius.circular(borderRadius);
    Widget inner;
    if (entry.coverPath.isNotEmpty && File(entry.coverPath).existsSync()) {
      inner = Image.file(File(entry.coverPath),
          fit: BoxFit.cover,
          width: double.infinity,
          height: double.infinity,
          errorBuilder: (_, _, _) => _placeholder());
    } else {
      inner = _placeholder();
    }
    return ClipRRect(borderRadius: r, child: inner);
  }

  Widget _placeholder() {
    final color = _palette[entry.title.hashCode.abs() % _palette.length];
    final ch = entry.title.isEmpty ? '?' : entry.title.characters.first;
    return Container(
      color: color,
      width: double.infinity,
      height: double.infinity,
      alignment: Alignment.center,
      child: Text(ch,
          style: const TextStyle(
              color: Colors.white,
              fontSize: 40,
              fontWeight: FontWeight.bold)),
    );
  }
}
