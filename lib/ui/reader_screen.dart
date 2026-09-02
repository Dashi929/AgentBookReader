import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../agent/agent_settings.dart';
import '../agent/llm_client.dart';
import '../agent/translation_providers.dart';
import '../core/controller/plain_text_document.dart';
import '../core/model/char_range.dart';
import '../core/model/document.dart';
import '../core/pagination/paginator.dart';
import '../infra/agent_repository.dart';
import '../l10n/app_localizations.dart';
import '../state/app_state.dart';
import 'agent_panel.dart';
import 'edit_section_screen.dart';

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

  _TranslateMode _translateMode = _TranslateMode.none;
  int? _selectedParagraph; // 选块模式下被选中的段落
  bool _translating = false;

  String get _docId => widget.entryId ?? widget.title;

  @override
  void initState() {
    super.initState();
    _currentPage = widget.initialPage;
    _pageController = PageController(initialPage: widget.initialPage);
    _load();
  }

  Future<void> _load() async {
    final format = switch (widget.format) {
      'md' => DocFormat.md,
      'json' => DocFormat.json,
      _ => DocFormat.txt,
    };
    final doc = await PlainTextDocument.create(
        _docId, widget.title, format, widget.initialContent);
    if (mounted) setState(() => _doc = doc);
  }

  @override
  void dispose() {
    _saveProgress();
    _pageController.dispose();
    super.dispose();
  }

  void _saveProgress() {
    if (widget.entryId == null) return;
    ref.read(libraryProvider.notifier).updateLastPage(_docId, _currentPage);
  }

  PlainTextDocument? get _activeDoc => _doc;

  void _repaginateIfNeeded(PlainTextDocument doc, double width, double height,
      double fontSize, String modeTag) {
    final key = '$modeTag|$width x $height x $fontSize';
    if (_paginationKey == key) return;
    _paginationKey = key;

    final anchorParagraph = _pages.isNotEmpty && _pageController.hasClients
        ? _currentAnchorParagraph()
        : -1;

    _pages = Paginator.paginate(doc.document,
        ReaderPageConfig(width: width, height: height, fontSize: fontSize));

    if (_pages.isEmpty) {
      _currentPage = 0;
      return;
    }

    int target;
    if (_jumped) {
      target = _pages.indexWhere(
          (p) => p.lines.any((l) => l.paragraphIndex == anchorParagraph));
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
          ? const Center(child: CircularProgressIndicator())
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
                        'original');
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
              if (_chromeVisible)
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
                              onPressed: () => Navigator.of(context).pop()),
                          Expanded(
                            child: Text(
                                selecting ? '选块翻译：点击要翻译的段落' : widget.title,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                    color: selecting
                                        ? Colors.teal
                                        : theme.text,
                                    fontSize: 17,
                                    fontWeight: FontWeight.w500)),
                          ),
                          IconButton(
                            tooltip: '编辑本节',
                            icon:
                                Icon(Icons.edit_outlined, color: theme.text),
                            onPressed: () {
                              final para = _currentAnchorParagraph();
                              var sectionIndex = 0;
                              for (final sec in doc.document.sections) {
                                if (sec.paragraphs
                                    .any((p) => p.index == para)) {
                                  sectionIndex = sec.index;
                                  break;
                                }
                              }
                              Navigator.of(context).push(MaterialPageRoute(
                                builder: (_) => EditSectionScreen(
                                  controller: doc,
                                  sectionIndex: sectionIndex,
                                  filePath: widget.entryId == null
                                      ? null
                                      : ref
                                          .read(libraryProvider.notifier)
                                          .byId(widget.entryId!)
                                          ?.path,
                                  format: widget.format,
                                ),
                              ));
                            },
                          ),
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
                          IconButton(
                            tooltip: s.annotations,
                            icon: Icon(Icons.speaker_notes_outlined,
                                color: theme.text),
                            onPressed: _showAnnotations,
                          ),
                          IconButton(
                            tooltip: s.agentPanel,
                            icon: Icon(Icons.auto_awesome,
                                color: _agentVisible
                                    ? Colors.teal
                                    : theme.text),
                            onPressed: () =>
                                setState(() => _agentVisible = !_agentVisible),
                          ),
                          IconButton(
                            icon: Icon(Icons.text_fields, color: theme.text),
                            onPressed: () =>
                                _showFontSheet(context, settings.fontSize),
                          ),
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
              if (selecting && _selectedParagraph != null)
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
              if (_agentVisible && _doc != null)
                AgentPanel(
                  docId: _docId,
                  controller: _doc!,
                  theme: theme,
                  onClose: () => setState(() => _agentVisible = false),
                ),
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
                onChanged: (v) {
                  setSheet(() => current = v);
                  ref.read(readerSettingsProvider.notifier).setFontSize(v);
                },
              ),
            ]),
          ),
        ),
      ),
    );
  }
}
