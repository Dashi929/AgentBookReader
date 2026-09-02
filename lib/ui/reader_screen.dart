import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pdfrx/pdfrx.dart';
import 'package:path_provider/path_provider.dart';

import '../agent/agent_settings.dart';
import '../agent/llm_client.dart';
import '../agent/translation_providers.dart';
import '../core/controller/plain_text_document.dart';
import '../core/model/annotation.dart';
import '../core/model/char_range.dart';
import '../core/model/document.dart';
import '../core/model/extracted_image.dart';
import '../core/pagination/paginator.dart';
import '../core/pagination/page_anchor.dart';
import '../infra/agent_repository.dart';
import '../l10n/app_localizations.dart';
import '../state/app_state.dart';
import 'agent_panel.dart';

/// 阅读器：分页翻页 / 主题 / 字号 / 进度记忆 / Agent / 编辑 / 整页与选块翻译。
/// 布局采用覆盖层：顶栏与页码悬浮在内容上方，显隐切换不改变内容区尺寸，
/// 因此永远不会触发重排（页码稳定、阅读位置不丢）。
enum _TranslateMode { none, block }

class ReaderScreen extends ConsumerStatefulWidget {
  const ReaderScreen({
    super.key,
    required this.title,
    required this.format,
    required this.initialContent,
    this.entryId,
    this.initialPage = 0,
  });

  final String title;
  final String format;
  final String initialContent;
  final String? entryId;
  final int initialPage;

  @override
  ConsumerState<ReaderScreen> createState() => _ReaderScreenState();
}

class _ReaderScreenState extends ConsumerState<ReaderScreen> {
  PlainTextDocument? _doc;
  List<ReaderPage> _pages = const [];
  String? _paginationKey;
  bool _jumped = false;
  late final PageController _pageController;
  bool _chromeVisible = true;
  bool _agentVisible = false;
  int _currentPage = 0;
  bool _editing = false;
  TextEditingController? _editController;
  Section? _editSection;
  bool _pdfLoading = false;
  LibraryNotifier? _libraryNotifier;
  final Map<String, ({String path, int w, int h})> _imageInfos = {};

  _TranslateMode _translateMode = _TranslateMode.none;
  int? _selectedParagraph; // 选块模式下被选中的段落
  bool _translating = false;

  String get _docId => widget.entryId ?? widget.title;

  /// 写回原文件仅对纯文本格式开放（docx/pdf 不回写）。
  bool get _writebackSupported {
    final ext = widget.format;
    return ext == 'txt' || ext == 'md' || ext == 'json';
  }

  @override
  void initState() {
    super.initState();
    _libraryNotifier = ref.read(libraryProvider.notifier);
    _currentPage = widget.initialPage;
    _pageController = PageController(initialPage: widget.initialPage);
    if (widget.format == 'pdf') {
      _extractPdf();
    } else {
      _load();
    }
  }

  Future<void> _load() async {
    final format = switch (widget.format) {
      'md' => DocFormat.md,
      'json' => DocFormat.json,
      _ => DocFormat.txt,
    };
    final doc = await PlainTextDocument.create(
        _docId, widget.title, format, widget.initialContent);
    await _loadImageManifest();
    if (mounted) setState(() => _doc = doc);
  }

  /// docx/epub 内嵌图片清单：`images/<entryId>/manifest.json`。
  Future<void> _loadImageManifest() async {
    if (widget.entryId == null) return;
    try {
      final support = await getApplicationSupportDirectory();
      final f = File('${support.path}/images/${widget.entryId}/manifest.json');
      if (!f.existsSync()) return;
      final raw = jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
      _imageInfos.clear();
      raw.forEach((id, info) {
        final map = info as Map<String, dynamic>;
        _imageInfos[id] = (
          path: '${support.path}/images/${widget.entryId}/${map['file']}',
          w: (map['w'] as num?)?.toInt() ?? 0,
          h: (map['h'] as num?)?.toInt() ?? 0,
        );
      });
    } catch (_) {}
  }

  /// 图片占位段 → 整行显示高度（按宽等比、限高）；非图片段返回 null。
  double? _imageLineHeightFor(String text, double width, double maxHeight) {
    final m = imagePlaceholderRegex.firstMatch(text.trim());
    if (m == null) return null;
    final info = _imageInfos[m.group(1)!];
    if (info == null || info.w <= 0 || info.h <= 0) return null;
    var h = width * info.h / info.w;
    if (h > maxHeight) h = maxHeight;
    if (h < 40) h = 40;
    return h + 8;
  }
  /// PDF → 文本管道：逐页 loadText 提取文字、书签（大纲）作为章节标题；
  /// 无文字页（扫描页）整页渲染为图片占位段。完成后走普通文本阅读管线。
  Future<void> _extractPdf() async {
    setState(() => _pdfLoading = true);
    try {
      final path = widget.entryId == null
          ? null
          : _libraryNotifier?.byId(widget.entryId!)?.path;
      if (path == null) throw '缺少 PDF 文件路径';
      final bytes = await File(path).readAsBytes();
      final pdf = await PdfDocument.openData(bytes);
      final bookmarks = <(String, int, int)>[]; // (标题, 1-based 页码, 层级)
      void walkOutline(List<PdfOutlineNode> nodes, int depth) {
        for (final n in nodes) {
          final page = n.dest?.pageNumber;
          if (page != null && n.title.trim().isNotEmpty) {
            bookmarks.add((n.title.trim(), page, depth));
          }
          walkOutline(n.children, depth + 1);
        }
      }

      walkOutline(await pdf.loadOutline(), 0);

      final md = StringBuffer();
      final manifest = <String, Map<String, dynamic>>{};
      Directory? imgDir;
      var bookmarkIdx = 0;
      for (var p = 1; p <= pdf.pages.length; p++) {
        while (bookmarkIdx < bookmarks.length &&
            bookmarks[bookmarkIdx].$2 <= p) {
          final (title, _, depth) = bookmarks[bookmarkIdx];
          final level = (depth + 1).clamp(1, 6);
          md.writeln('${'#' * level} $title');
          bookmarkIdx++;
        }
        // 无书签的 PDF：每页作为一个章节（标题"第 N 页"）
        if (bookmarks.isEmpty) md.writeln('# 第 $p 页');
        final page = pdf.pages[p - 1];
        final rawText = (await page.loadText())?.fullText.trim() ?? '';
        if (rawText.isNotEmpty) {
          md.writeln(rawText);
        } else {
          // 无文字页（扫描页）：整页渲染为图片
          final targetW = 1080;
          final image = await page.render(
              fullWidth: targetW.toDouble(),
              fullHeight: targetW * page.height / page.width);
          if (image != null) {
            imgDir ??= Directory(
                    '${(await getApplicationSupportDirectory()).path}/images/${widget.entryId}')
              ..createSync(recursive: true);
            final rgba = Uint8List(image.pixels.length);
            for (var i = 0; i < image.pixels.length; i += 4) {
              rgba[i] = image.pixels[i + 2];
              rgba[i + 1] = image.pixels[i + 1];
              rgba[i + 2] = image.pixels[i];
              rgba[i + 3] = image.pixels[i + 3];
            }
            final buffer = await ui.ImmutableBuffer.fromUint8List(rgba);
            final descriptor = ui.ImageDescriptor.raw(buffer,
                width: image.width,
                height: image.height,
                pixelFormat: ui.PixelFormat.rgba8888);
            final codec = await descriptor.instantiateCodec();
            final frameData = await codec.getNextFrame();
            final png = await frameData.image
                .toByteData(format: ui.ImageByteFormat.png);
            frameData.image.dispose();
            codec.dispose();
            descriptor.dispose();
            buffer.dispose();
            image.dispose();
            if (png != null) {
              final id = 'pdfp$p';
              final f = File('${imgDir.path}/$id.png');
              f.writeAsBytesSync(png.buffer
                  .asUint8List(png.offsetInBytes, png.lengthInBytes));
              manifest[id] = {
                'file': '$id.png',
                'w': image.width,
                'h': image.height
              };
              md.writeln('[[IMG:$id]]');
            }
          }
        }
        md.writeln('');
      }
      pdf.dispose();
      if (manifest.isNotEmpty) {
        final dir = imgDir!;
        File('${dir.path}/manifest.json')
            .writeAsStringSync(jsonEncode(manifest));
        manifest.forEach((id, info) {
          _imageInfos[id] = (
            path: '${dir.path}/${info['file']}',
            w: (info['w'] as num).toInt(),
            h: (info['h'] as num).toInt(),
          );
        });
      }
      final doc = await PlainTextDocument.create(
          _docId, widget.title, DocFormat.md, md.toString());
      if (mounted) setState(() => _doc = doc);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('PDF 解析失败：$e')));
      }
    } finally {
      if (mounted) setState(() => _pdfLoading = false);
    }
  }

  @override
  void dispose() {
    _saveProgress();
    _pageController.dispose();
    super.dispose();
  }

  void _saveProgress() {
    if (widget.entryId == null) return;
    // dispose 期间不能再用 ref（riverpod 抛 "ref after disposed"），
    // initState 时先捕获 notifier。
    _libraryNotifier?.updateLastPage(_docId, _currentPage);
  }

  PlainTextDocument? get _activeDoc => _doc;

  void _repaginateIfNeeded(PlainTextDocument doc, double width, double height,
      double fontSize, String modeTag,
      {double? Function(String)? imageLineHeight}) {
    final key = '$modeTag|$width x $height x $fontSize';
    if (_paginationKey == key) return;
    _paginationKey = key;

    // 字符级锚点：跨页段落/字号变更后精确保留位置（见 PageAnchor）。
    int? anchorCharOffset;
    if (_pages.isNotEmpty && _pageController.hasClients) {
      final idx = _pageController.page?.round() ?? _currentPage;
      if (idx >= 0 && idx < _pages.length) {
        anchorCharOffset =
            PageAnchor.charOffsetForPageTop(_pages[idx], doc.document);
      }
    }

    _pages = Paginator.paginate(
        doc.document,
        ReaderPageConfig(
            width: width,
            height: height,
            fontSize: fontSize,
            imageLineHeight: imageLineHeight));

    if (_pages.isEmpty) {
      _currentPage = 0;
      return;
    }

    int target;
    if (_jumped) {
      target = -1;
      if (anchorCharOffset != null) {
        target = PageAnchor.targetPage(_pages, doc.document, anchorCharOffset);
      }
      if (target == -1) target = 0;
    } else {
      target = widget.initialPage.clamp(0, _pages.length - 1);
      _jumped = true;
    }

    WidgetsBinding.instance.addPostFrameCallback((_) => _jumpWhenReady(target));
  }

  void _jumpWhenReady(int target) {
    if (_pageController.hasClients) {
      _pageController.jumpToPage(target);
      _currentPage = target;
      if (mounted) setState(() {});
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _pageController.hasClients) {
        _pageController.jumpToPage(target);
        _currentPage = target;
        if (mounted) setState(() {});
      }
    });
  }

  int _currentAnchorParagraph() {
    final idx = _pageController.page?.round() ?? _currentPage;
    if (idx < 0 || idx >= _pages.length) return -1;
    final lines = _pages[idx].lines;
    return lines.isEmpty ? -1 : lines.first.paragraphIndex;
  }

  //================ 就地编辑（不打开新窗口） ================

  void _startEditing(PlainTextDocument doc) {
    final para = _currentAnchorParagraph();
    var sectionIndex = 0;
    for (final sec in doc.document.sections) {
      if (sec.paragraphs.any((p) => p.index == para)) {
        sectionIndex = sec.index;
        break;
      }
    }
    final section = doc.sectionAt(sectionIndex);
    if (section == null) return;
    setState(() {
      _editing = true;
      _editSection = section;
      _editController = TextEditingController(text: section.plainText);
    });
  }

  void _cancelEditing() {
    setState(() {
      _editing = false;
      _editController?.dispose();
      _editController = null;
      _editSection = null;
    });
  }

  Future<void> _applyEditing(PlainTextDocument doc) async {
    final s = AppLocalizations.of(context)!;
    final section = _editSection;
    final controller = _editController;
    if (section == null || controller == null) return;
    await doc.applyEdit(DocTextEdit.replace(
      CharRange(section.charOffset, section.charOffset + section.charCount),
      '${controller.text}\n\n',
    ));

    String? note;
    if (widget.entryId != null && _writebackSupported) {
      final path =
          ref.read(libraryProvider.notifier).byId(widget.entryId!)?.path;
      if (path != null) {
        try {
          // 写回原文件前先备份 .bak
          final bytes = await XFile(path).readAsBytes();
          await XFile.fromData(bytes).saveTo('$path.bak');
          final out = widget.format == 'json'
              ? jsonEncode(doc.document.sections
                  .map((sec) => {
                        'index': sec.index,
                        'title': sec.title,
                        'text': sec.plainText,
                      })
                  .toList())
              : doc.rawText;
          await XFile.fromData(utf8.encode(out)).saveTo(path);
          note = '（原文件已备份并更新）';
        } catch (e) {
          note = null;
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text('写回原文件失败：$e（编辑已保存）')));
          }
        }
      }
    }
    if (note == null && !_writebackSupported) {
      note = '（该格式编辑仅保存在应用内，可导出）';
    }
    setState(() {
      _editing = false;
      _editController?.dispose();
      _editController = null;
      _editSection = null;
      _paginationKey = null; // 内容已变，强制按新文本重排
    });
    if (mounted && note != null) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('${s.confirm}$note')));
    }
  }

  /// 导出（另存）或写回原文件（.bak 备份）。exportAs=false 且有原文件时写回。
  Future<void> _exportOrSaveDoc(PlainTextDocument doc,
      {required bool exportAs}) async {
    final s = AppLocalizations.of(context)!;
    String? targetPath = widget.entryId == null
        ? null
        : ref.read(libraryProvider.notifier).byId(widget.entryId!)?.path;
    if (exportAs || targetPath == null || !_writebackSupported) {
      final ext = _writebackSupported ? widget.format : 'txt';
      final location = await getSaveLocation(
          suggestedName: '${doc.document.title}.$ext');
      if (location == null) return;
      targetPath = location.path;
    } else {
      final bytes = await XFile(targetPath).readAsBytes();
      await XFile.fromData(bytes).saveTo('$targetPath.bak');
    }
    final out = targetPath.split('.').last.toLowerCase() == 'json'
        ? jsonEncode(doc.document.sections
            .map((sec) => {
                  'index': sec.index,
                  'title': sec.title,
                  'text': sec.plainText,
                })
            .toList())
        : doc.rawText;
    await XFile.fromData(utf8.encode(out)).saveTo(targetPath);
    if (mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('${s.confirm}: $targetPath')));
    }
  }


  //================ 翻译（整页 / 选块） ================

  Paragraph? _paragraphByIndex(int paragraphIndex) {
    for (final s in _doc!.document.sections) {
      for (final p in s.paragraphs) {
        if (p.index == paragraphIndex) return p;
      }
    }
    return null;
  }

  String get _currentPageText {
    final idx = _pageController.page?.round() ?? _currentPage;
    if (idx < 0 || idx >= _pages.length) return '';
    return _pages[idx]
        .lines
        .map((l) => l.segments.map((s) => s.text).join())
        .join('\n');
  }

  /// 批注列表（含 Agent 添加的）。
  Future<void> _showAnnotations() async {
    final s = AppLocalizations.of(context)!;
    final anns = await AgentRepository(ref.read(appDatabaseProvider))
        .annotationsFor(_docId);
    if (!mounted) return;
    showModalBottomSheet(
      context: context,
      builder: (context) => SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(12),
          shrinkWrap: true,
          children: [
            Text(s.annotations,
                style:
                    const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            if (anns.isEmpty)
              const Padding(
                  padding: EdgeInsets.all(12), child: Text('暂无批注')),
            ...anns.map((a) => Card(
                  child: Padding(
                    padding: const EdgeInsets.all(10),
                    child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(a.content,
                              style: const TextStyle(fontSize: 14)),
                          const SizedBox(height: 4),
                          Text(
                              '原文: ${a.originalText.isEmpty ? "-" : a.originalText}',
                              style: TextStyle(
                                  fontSize: 12,
                                  color: Colors.grey.shade600)),
                        ]),
                  ),
                )),
          ],
        ),
      ),
    );
  }

  Future<void> _openTranslateMenu() async {
    final s = AppLocalizations.of(context)!;
    // 先选目标语言（记忆上次选择），再选翻译范围
    final langCode = await showDialog<String>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('翻译到…'),
        children: [
          for (final (code, name) in targetLanguages)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(context, code),
              child: ListTile(
                leading: code == PrefsService.instance.loadTargetLang()
                    ? const Icon(Icons.check, color: Colors.teal)
                    : const Icon(Icons.language),
                title: Text(name),
              ),
            ),
        ],
      ),
    );
    if (langCode == null || !mounted) return;
    PrefsService.instance.saveTargetLang(langCode);
    final langName = targetLangName(langCode);

    final choice = await showDialog<String>(
      context: context,
      builder: (context) => SimpleDialog(
        title: Text('$s.translate · $langName'),
        children: [
          SimpleDialogOption(
            onPressed: () => Navigator.pop(context, 'page'),
            child: ListTile(
                leading: const Icon(Icons.auto_stories),
                title: Text('整页翻译'),
                subtitle: const Text('翻译当前页可见内容')),
          ),
          SimpleDialogOption(
            onPressed: () => Navigator.pop(context, 'block'),
            child: ListTile(
                leading: const Icon(Icons.format_align_left),
                title: Text('选块翻译'),
                subtitle: const Text('点击段落进行选择，整段翻译')),
          ),
        ],
      ),
    );
    if (!mounted) return;
    if (choice == 'page') {
      final text = _currentPageText.trim();
      if (text.isEmpty) return;
      await _translateAndShow(text,
          title: '整页 · 第${_currentPage + 1}页 · $langName', targetLang: langCode);
    } else if (choice == 'block') {
      setState(() {
        _translateMode = _TranslateMode.block;
        _selectedParagraph = null;
      });
    }
  }

  Future<void> _translateSelectedBlock() async {
    final para = _paragraphByIndex(_selectedParagraph ?? -1);
    if (para == null) return;
    final text = para.plainText.trim();
    if (text.isEmpty) return;
    final langCode = PrefsService.instance.loadTargetLang();
    final langName = targetLangName(langCode);
    await _translateAndShow(text,
        title: '选块 · 第${(_selectedParagraph! + 1)}段 · $langName',
        targetLang: langCode);
    if (mounted) {
      setState(() {
        _translateMode = _TranslateMode.none;
        _selectedParagraph = null;
      });
    }
  }

  Future<void> _translateAndShow(String text,
      {required String title, String targetLang = 'zh'}) async {
    final s = AppLocalizations.of(context)!;
    final providerId = PrefsService.instance.loadTranslationProvider();
    final settings = await AgentSettings.instance.read();
    final provider = buildTranslationProvider(
      providerId,
      llmClient: LlmClient(
          baseUrl: settings.baseUrl,
          apiKey: settings.apiKey,
          model: settings.model),
    );

    setState(() => _translating = true);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('${s.translate}…（${provider.label}）'),
        duration: const Duration(seconds: 2)));
    try {
      final result = await provider.translate(text, targetLang: targetLang);
      if (mounted) _showResultSheet(title, result);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('${s.translate}失败: $e')));
      }
    } finally {
      if (mounted) setState(() => _translating = false);
    }
  }

  void _showResultSheet(String title, String result) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (context) => DraggableScrollableSheet(
        initialChildSize: 0.5,
        maxChildSize: 0.9,
        expand: false,
        builder: (context, scrollController) => Container(
          padding: const EdgeInsets.all(16),
          child: Column(children: [
            Row(children: [
              Text(title,
                  style: const TextStyle(
                      fontSize: 15, fontWeight: FontWeight.bold)),
              const Spacer(),
              IconButton(
                icon: const Icon(Icons.copy, size: 18),
                tooltip: '复制',
                onPressed: () {
                  Clipboard.setData(ClipboardData(text: result));
                  ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('已复制')));
                },
              ),
              IconButton(
                  icon: const Icon(Icons.close, size: 18),
                  onPressed: () => Navigator.pop(context)),
            ]),
            const Divider(),
            Expanded(
              child: SingleChildScrollView(
                controller: scrollController,
                child: SelectableText(result,
                    style: const TextStyle(fontSize: 15, height: 1.6)),
              ),
            ),
          ]),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(readerSettingsProvider);
    final theme = ReaderTheme.presets[settings.theme.clamp(0, 2)];
    final s = AppLocalizations.of(context)!;
    final doc = _activeDoc;
    final selecting = _translateMode == _TranslateMode.block;
    return Scaffold(
      backgroundColor: theme.background,
      body: doc == null
          ? Center(
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                const CircularProgressIndicator(),
                if (_pdfLoading)
                  const Padding(
                      padding: EdgeInsets.only(top: 12),
                      child: Text('正在解析 PDF…')),
              ]))
          : Stack(children: [
              Positioned.fill(
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTapUp: selecting
                      ? null
                      : (d) {
                          final w = MediaQuery.of(context).size.width;
                          if (d.globalPosition.dx < w * 0.3) {
                            _pageController.previousPage(
                                duration: const Duration(milliseconds: 200),
                                curve: Curves.easeOut);
                          } else if (d.globalPosition.dx > w * 0.7) {
                            _pageController.nextPage(
                                duration: const Duration(milliseconds: 200),
                                curve: Curves.easeOut);
                          } else {
                            setState(() => _chromeVisible = !_chromeVisible);
                          }
                        },
                  child: LayoutBuilder(builder: (context, constraints) {
                    _repaginateIfNeeded(
                        doc,
                        constraints.maxWidth - 32,
                        constraints.maxHeight - 48,
                        settings.fontSize,
                        'original',
                        imageLineHeight: (t) => _imageLineHeightFor(
                            t,
                            constraints.maxWidth - 32,
                            (constraints.maxHeight - 48) * 0.6));
                    return Padding(
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
                      child: PageView.builder(
                        controller: _pageController,
                        itemCount: _pages.length,
                        onPageChanged: (page) {
                          _currentPage = page;
                          setState(() {});
                          _saveProgress();
                        },
                        itemBuilder: (context, i) => _buildPage(_pages[i],
                            theme: theme, fontSize: settings.fontSize,
                            selecting: selecting),
                      ),
                    );
                  }),
                ),
              ),
              if (!_editing)
                Positioned(
                left: 0,
                right: 0,
                bottom: 6,
                child: IgnorePointer(
                  child: Center(
                    child: Text(
                      '${_currentPage + 1} / ${_pages.length}',
                      style: TextStyle(
                          color: theme.text.withValues(alpha: 0.45),
                          fontSize: 12),
                    ),
                  ),
                ),
              ),
              if (_chromeVisible || _editing)
                Positioned(
                  top: 0,
                  left: 0,
                  right: 0,
                  child: Material(
                    color: theme.background.withValues(alpha: 0.96),
                    elevation: 2,
                    child: SafeArea(
                      bottom: false,
                      child: SizedBox(
                        height: 56,
                        child: Row(children: [
                          const SizedBox(width: 4),
                          BackButton(
                              color: theme.text,
                              onPressed: () {
                                if (_editing) {
                                  _cancelEditing();
                                } else {
                                  Navigator.of(context).pop();
                                }
                              }),
                          Expanded(
                            child: Text(
                                selecting
                                    ? '选块翻译：点击要翻译的段落'
                                    : _editing
                                        ? '编辑 · ${s.section((_editSection?.index ?? 0) + 1)}'
                                        : widget.title,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                    color: (selecting || _editing)
                                        ? Colors.teal
                                        : theme.text,
                                    fontSize: 17,
                                    fontWeight: FontWeight.w500)),
                          ),
                          if (_editing) ...[
                            IconButton(
                              tooltip: s.confirm,
                              icon: Icon(Icons.check, color: theme.text),
                              onPressed: () => _applyEditing(doc),
                            ),
                            IconButton(
                              tooltip: '导出',
                              icon: Icon(Icons.file_download_outlined,
                                  color: theme.text),
                              onPressed: () =>
                                  _exportOrSaveDoc(doc, exportAs: true),
                            ),
                            if (widget.entryId != null &&
                                _writebackSupported)
                              IconButton(
                                icon: Icon(Icons.drive_file_move_outline,
                                    color: theme.text),
                                tooltip: '写入原文件(.bak)',
                                onPressed: () =>
                                    _exportOrSaveDoc(doc, exportAs: false),
                              ),
                            IconButton(
                              tooltip: '取消',
                              icon: Icon(Icons.close, color: theme.text),
                              onPressed: _cancelEditing,
                            ),
                          ] else
                            IconButton(
                              tooltip: '编辑本节',
                              icon:
                                  Icon(Icons.edit_outlined, color: theme.text),
                              onPressed: () => _startEditing(doc),
                            ),
                          if (!_editing &&
                              doc.document.sections.length > 1)
                            IconButton(
                              tooltip: s.chapters,
                              icon: Icon(Icons.menu_book, color: theme.text),
                              onPressed: _showSectionList,
                            ),
                          if (!_editing)
                            IconButton(
                            tooltip: _translating ? '翻译中…' : s.translate,
                            icon: _translating
                                ? const SizedBox(
                                    width: 18,
                                    height: 18,
                                    child: CircularProgressIndicator(
                                        strokeWidth: 2))
                                : Icon(Icons.translate, color: theme.text),
                            onPressed: _translating ? null : _openTranslateMenu,
                          ),
                          if (!_editing)
                            IconButton(
                            tooltip: s.annotations,
                            icon: Icon(Icons.speaker_notes_outlined,
                                color: theme.text),
                            onPressed: _showAnnotations,
                          ),
                          if (!_editing)
                            IconButton(
                            tooltip: s.agentPanel,
                            icon: Icon(Icons.auto_awesome,
                                color: _agentVisible
                                    ? Colors.teal
                                    : theme.text),
                            onPressed: () =>
                                setState(() => _agentVisible = !_agentVisible),
                          ),
                          if (!_editing)
                            IconButton(
                            icon: Icon(Icons.text_fields, color: theme.text),
                            onPressed: () =>
                                _showFontSheet(context, settings.fontSize),
                          ),
                          if (!_editing)
                            IconButton(
                            icon:
                                Icon(Icons.palette_outlined, color: theme.text),
                            onPressed: () => ref
                                .read(readerSettingsProvider.notifier)
                                .setTheme((settings.theme + 1) % 3),
                          ),
                          const SizedBox(width: 8),
                        ]),
                      ),
                    ),
                  ),
                ),
              if (_editing)
                Positioned(
                  left: 0,
                  right: 0,
                  top: 110,
                  bottom: 0,
                  child: Material(
                    color: theme.background,
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: TextField(
                        controller: _editController,
                        maxLines: null,
                        expands: true,
                        textAlignVertical: TextAlignVertical.top,
                        style: TextStyle(color: theme.text, fontSize: 15),
                        decoration: const InputDecoration(
                            border: OutlineInputBorder(), isDense: true),
                      ),
                    ),
                  ),
                ),
              if (!_editing && selecting && _selectedParagraph != null)
                Positioned(
                  right: 16,
                  bottom: 100,
                  child: Column(children: [
                    FloatingActionButton.extended(
                      heroTag: 'translateBlock',
                      backgroundColor: Colors.teal,
                      onPressed: _translating ? null : _translateSelectedBlock,
                      icon: _translating
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(
                                  strokeWidth: 2, color: Colors.white))
                          : const Icon(Icons.translate),
                      label: const Text('翻译此段'),
                    ),
                    const SizedBox(height: 8),
                    FloatingActionButton.small(
                      heroTag: 'cancelSelect',
                      onPressed: () => setState(() {
                        _translateMode = _TranslateMode.none;
                        _selectedParagraph = null;
                      }),
                      child: const Icon(Icons.close),
                    ),
                  ]),
                ),
              if (!_editing && _agentVisible && _doc != null)
                AgentPanel(
                  docId: _docId,
                  controller: _doc!,
                  theme: theme,
                  onClose: () => setState(() => _agentVisible = false),
                ),
              if (!_editing)
                Positioned(
                right: 16,
                bottom: 30,
                child: FloatingActionButton(
                  heroTag: 'agentFab',
                  backgroundColor: Colors.teal,
                  foregroundColor: Colors.white,
                  onPressed: () =>
                      setState(() => _agentVisible = !_agentVisible),
                  child: const Icon(Icons.auto_awesome),
                ),
              ),
            ]),
    );
  }

  Widget _buildPage(ReaderPage page,
      {required ReaderTheme theme, required double fontSize, required bool selecting}) {
    final children = <Widget>[];
    var lastParagraph = -1;
    for (final line in page.lines) {
      // 图片占位行：整行渲染内嵌图片（docx/epub 提取）
      final lineText = line.segments.map((s) => s.text).join();
      final imgMatch =
          imagePlaceholderRegex.firstMatch(lineText.trim());
      final imgInfo = imgMatch == null ? null : _imageInfos[imgMatch.group(1)!];
      if (imgInfo != null) {
        if (lastParagraph != -1 && line.paragraphIndex != lastParagraph) {
          children.add(const SizedBox(height: 10));
        }
        final selected = _translateMode == _TranslateMode.block &&
            line.paragraphIndex == _selectedParagraph;
        children.add(SizedBox(
          height: line.height,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: _translateMode == _TranslateMode.block
                ? () {
                    setState(() => _selectedParagraph = line.paragraphIndex);
                  }
                : null,
            child: Container(
              color: selected
                  ? Colors.teal.withValues(alpha: 0.18)
                  : null,
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Image.file(
                File(imgInfo.path),
                fit: BoxFit.contain,
                width: double.infinity,
                errorBuilder: (_, _, _) => Align(
                    alignment: Alignment.centerLeft,
                    child: Text(lineText,
                        style: TextStyle(
                            fontSize: fontSize, color: theme.text))),
              ),
            ),
          ),
        ));
        lastParagraph = line.paragraphIndex;
        continue;
      }
      if (lastParagraph != -1 && line.paragraphIndex != lastParagraph) {
        children.add(const SizedBox(height: 10));
      }
      final selected = _translateMode == _TranslateMode.block &&
          line.paragraphIndex == _selectedParagraph;
      children.add(SizedBox(
        height: line.height,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap:
              _translateMode == _TranslateMode.block ? () {
            setState(() => _selectedParagraph = line.paragraphIndex);
          } : null,
          child: Container(
            color: selected ? Colors.teal.withValues(alpha: 0.18) : null,
            child: RichText(
              maxLines: 1,
              softWrap: false,
              overflow: TextOverflow.clip,
              text: TextSpan(
                children: line.segments
                    .map((seg) => TextSpan(text: seg.text))
                    .toList(),
                style: TextStyle(fontSize: fontSize, color: theme.text),
              ),
            ),
          ),
        ),
      ));
      lastParagraph = line.paragraphIndex;
    }
    return SingleChildScrollView(
      physics: const NeverScrollableScrollPhysics(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: children,
      ),
    );
  }

  /// 章节目录：列出所有 Section（标题 + 起始页），点击跳转。
  void _showSectionList() {
    final s = AppLocalizations.of(context)!;
    final doc = _doc;
    if (doc == null) return;
    final paraSection = <int, int>{};
    for (final sec in doc.document.sections) {
      for (final p in sec.paragraphs) {
        paraSection[p.index] = sec.index;
      }
    }
    showModalBottomSheet(
      context: context,
      builder: (context) => SafeArea(
        child: SizedBox(
          height: MediaQuery.of(context).size.height * 0.6,
          child: ListView.builder(
            itemCount: doc.document.sections.length,
            itemBuilder: (context, i) {
              final sec = doc.document.sections[i];
              var page = -1;
              for (var pi = 0; pi < _pages.length && page == -1; pi++) {
                for (final line in _pages[pi].lines) {
                  if (paraSection[line.paragraphIndex] == sec.index) {
                    page = pi;
                    break;
                  }
                }
              }
              return ListTile(
                dense: true,
                title: Text(
                    sec.title.isEmpty ? s.section(i + 1) : sec.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis),
                subtitle:
                    page >= 0 ? Text(s.page(page + 1)) : null,
                onTap: () {
                  Navigator.pop(context);
                  if (page >= 0) _jumpWhenReady(page);
                },
              );
            },
          ),
        ),
      ),
    );
  }
  void _showFontSheet(BuildContext context, double current) {
    final s = AppLocalizations.of(context)!;
    showModalBottomSheet(
      context: context,
      builder: (context) => SafeArea(
        child: StatefulBuilder(
          builder: (context, setSheet) => Padding(
            padding: const EdgeInsets.all(16),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Text('${s.reader}  $current'),
              Slider(
                value: current,
                min: 12,
                max: 32,
                divisions: 20,
                label: current.toStringAsFixed(0),
                // 拖动中只更新预览数值：连续 setFontSize 会触发多次重排，
                // 每次以"当前页首段"为锚点会造成锚点漂移（bug 修复）。
                onChanged: (v) => setSheet(() => current = v),
                onChangeEnd: (v) =>
                    ref.read(readerSettingsProvider.notifier).setFontSize(v),
              ),
            ]),
          ),
        ),
      ),
    );
  }
}
