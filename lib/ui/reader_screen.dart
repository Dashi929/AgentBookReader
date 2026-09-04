import 'dart:convert';
import 'dart:math' as math;
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pdfrx/pdfrx.dart';
import 'package:path_provider/path_provider.dart';

import '../agent/agent_settings.dart';
import '../core/io/pdf_render.dart';
import '../agent/llm_client.dart';
import '../agent/translation_providers.dart';
import '../core/controller/plain_text_document.dart';
import '../core/model/annotation.dart';
import '../core/model/char_range.dart';
import '../core/model/document.dart';
import '../core/model/extracted_image.dart'
    show ensureStandaloneImageLines, imagePlaceholderRegex;
import '../core/pagination/paginator.dart';
import '../core/pagination/page_anchor.dart';
import '../l10n/app_localizations.dart';
import '../state/app_state.dart';
import 'agent_panel.dart';
import 'pptx_view.dart';
import 'xlsx_view.dart';
import '../core/parser/pptx_extractor.dart';
import '../core/parser/xlsx_extractor.dart';

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
    this.initialSection,
  });

  final String title;
  final String format;
  final String initialContent;
  final String? entryId;
  final int initialPage;

  /// 从详情页章节进入时：优先跳到该节（文字格式），优先级高于 initialPage
  final int? initialSection;

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

  // PDF 原版渲染模式：阅读视图逐页显示 pdfium 渲染图（保真，含图示），
  // _doc 仍持有提取文字（仅供 Agent 工具 / 整页翻译 / 批注）。
  PdfDocument? _pdfDoc;
  int _pdfPageCount = 0;
  List<String> _pdfPageTexts = const [];
  List<(String, int, int)> _pdfBookmarks = const []; // (标题, 1-based 页码, 层级)
  final Map<int, ({String path, int w, int h})> _pdfRendered = {};
  final Set<int> _pdfRendering = {};
  final Map<int, Future<({String path, int w, int h})?>> _pdfFutures = {};

  bool get _isPdf => widget.format == 'pdf' && _pdfDoc != null;

  // xlsx/pptx/cbz 专属渲染模式（Office 视觉近似 / 漫画整页）
  List<XlsxSheetData>? _xlsxSheets;
  List<PptSlideData>? _pptxSlides;
  List<({String path, int w, int h})> _comicPages = const [];
  List<String> _officePageTexts = const []; // 每页文本（整页翻译用）

  bool _pendingEdits = false; // 已确认的编辑（退出时询问另存/覆盖/放弃）
  TextSelection? _sheetSelection; // 文字选择面板中的当前选区
  bool _continuous = PrefsService.instance.loadReaderContinuous();
  // 连续模式整体双指缩放（Listener 手势不进 arena，不影响单指滚动/点击）
  final Map<int, Offset> _pinchPtrs = {};
  double _pinchPrevDist = 0;
  Offset _pinchPrevMid = Offset.zero;
  double _contZoom = 1.0;
  Offset _contPan = Offset.zero;

  void _onPinchDown(PointerEvent e) {
    _pinchPtrs[e.pointer] = e.position;
    if (_pinchPtrs.length == 2) {
      final v = _pinchPtrs.values.toList();
      _pinchPrevDist = (v[0] - v[1]).distance;
      _pinchPrevMid = (v[0] + v[1]) / 2;
    }
  }

  void _onPinchMove(PointerEvent e) {
    if (!_pinchPtrs.containsKey(e.pointer)) return;
    _pinchPtrs[e.pointer] = e.position;
    if (_pinchPtrs.length != 2) return;
    final v = _pinchPtrs.values.toList();
    final d = (v[0] - v[1]).distance;
    final mid = (v[0] + v[1]) / 2;
    if (_pinchPrevDist > 0) {
      _contZoom = (_contZoom * d / _pinchPrevDist).clamp(1.0, 4.0);
      final maxPan = (_contZoom - 1) * 600.0;
      _contPan = Offset(
          (_contPan.dx + mid.dx - _pinchPrevMid.dx).clamp(-maxPan, maxPan),
          (_contPan.dy + mid.dy - _pinchPrevMid.dy).clamp(-maxPan, maxPan));
      if (mounted) setState(() {});
    }
    _pinchPrevDist = d;
    _pinchPrevMid = mid;
  }

  void _onPinchUp(PointerEvent e) {
    _pinchPtrs.remove(e.pointer);
    _pinchPrevDist = 0;
  }
  List<double> _contOffsets = const [0.0];
  final ScrollController _continuousController = ScrollController();

  bool get _isXlsx => widget.format == 'xlsx' && _xlsxSheets != null;
  bool get _isPptx => widget.format == 'pptx' && _pptxSlides != null;
  bool get _isComic => widget.format == 'cbz' && _comicPages.isNotEmpty;
  bool get _officeMode => _isPdf || _isXlsx || _isPptx || _isComic;
  int get _officePageCount => _isPdf
      ? _pdfPageCount
      : _isXlsx
          ? _xlsxSheets!.length
          : _isPptx
              ? _pptxSlides!.length
              : _isComic
                  ? _comicPages.length
                  : 0;

  /// 当前页文本（整页翻译用）。
  String get _currentPageOfficeText =>
      (_currentPage >= 0 && _currentPage < _officePageTexts.length)
          ? _officePageTexts[_currentPage]
          : '';

  _TranslateMode _translateMode = _TranslateMode.none;
  int? _selectedParagraph; // 选块模式下被选中的段落
  bool _translating = false;

  /// 宽屏设备（平板/桌面）不锁定方向，阅读器随设备旋转重新分页。
  bool _wideScreen = false;

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
    // PDF 页数未知（progress 可能来自旧的文本分页模式），先定位第 0 页，
    // 提取完成后再跳到 clamp 后的进度页
    _pageController =
        PageController(initialPage: widget.format == 'pdf' ? 0 : widget.initialPage);
    _continuousController.addListener(_onContinuousScroll);
    _applyComfortSettings();
    switch (widget.format) {
      case 'pdf':
        _extractPdf();
      case 'xlsx':
        _load();
        _loadXlsx();
      case 'pptx':
        _load();
        _loadPptx();
      case 'cbz':
        _load();
        _loadComic();
      default:
        _load();
    }
    _applyOrientation();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // initState 阶段不能依赖 MediaQuery，这里补算宽屏标记并重应用方向
    final wide = MediaQuery.of(context).size.shortestSide >= 600;
    if (wide != _wideScreen) {
      _wideScreen = wide;
      _applyOrientation();
    }
  }

  /// 应用常亮/沉浸（进入时按偏好，弹窗切换时实时更新）。
  void _applyComfortSettings() {
    final st = ref.read(readerSettingsProvider);
    if (st.keepAwake) {
      WakelockPlus.enable();
    } else {
      WakelockPlus.disable();
    }
    if (st.immersive) {
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    } else {
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    }
  }

  /// ppt/xlsx 单页模式默认横屏；连续模式竖屏（纵向滚动）。
  /// 宽屏设备（平板）不锁方向：阅读器支持横竖重排，交给用户旋转。
  void _applyOrientation() {
    if (_wideScreen) {
      SystemChrome.setPreferredOrientations(const [
        DeviceOrientation.portraitUp,
        DeviceOrientation.landscapeLeft,
        DeviceOrientation.landscapeRight,
      ]);
      return;
    }
    final landscape =
        (widget.format == 'pptx' || widget.format == 'xlsx') && !_continuous;
    SystemChrome.setPreferredOrientations(landscape
        ? [DeviceOrientation.landscapeLeft, DeviceOrientation.landscapeRight]
        : [DeviceOrientation.portraitUp]);
  }

  void _toggleContinuous() {
    setState(() {
      _continuous = !_continuous;
      PrefsService.instance.saveReaderContinuous(_continuous);
    });
    _applyOrientation();
    if (_continuous) {
      // 单页→连续：滚到当前页
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!_scrollReady) return;
        double target;
        if (_contOffsets.length == _officePageCount + 1) {
          target = _contOffsets[_currentPage.clamp(0, _officePageCount - 1)];
        } else {
          target = _currentPage * _continuousController.position.viewportDimension;
        }
        _continuousController.jumpTo(
            math.min(target, _continuousController.position.maxScrollExtent));
      });
    } else {
      // 连续→单页：跳回当前页
      _jumpWhenReady(_currentPage);
    }
  }

  bool get _scrollReady =>
      _continuousController.hasClients &&
      _continuousController.position.viewportDimension > 0;

  /// 连续模式：滚动位置 → 当前页（xlsx 按 sheet 累计高度，其余按视口）。
  void _onContinuousScroll() {
    if (!_scrollReady || !_officeMode) return;
    int page;
    if (_contOffsets.length == _officePageCount + 1) {
      // 累计偏移查找（二分）
      final off = _continuousController.offset;
      int lo = 0, hi = _officePageCount - 1, res = 0;
      while (lo <= hi) {
        final mid = (lo + hi) >> 1;
        if (_contOffsets[mid] <= off) {
          res = mid;
          lo = mid + 1;
        } else {
          hi = mid - 1;
        }
      }
      page = res;
    } else {
      final vp = _continuousController.position.viewportDimension;
      page = (_continuousController.offset / vp).round();
    }
    page = page.clamp(0, math.max(_officePageCount - 1, 0));
    if (page != _currentPage) {
      _currentPage = page;
      _saveProgress();
      if (mounted) setState(() {});
    }
  }

  Future<void> _loadXlsx() async {
    try {
      final path = widget.entryId == null
          ? null
          : _libraryNotifier?.byId(widget.entryId!)?.path;
      if (path == null) throw '缺少文件路径';
      final bytes = await File(path).readAsBytes();
      final sheets = parseXlsxSheets(bytes);
      final texts = <String>[];
      for (final sh in sheets) {
        final buf = StringBuffer('# ${sh.name}\n');
        for (var r = 0; r < sh.rows; r++) {
          final cells = sh.cells[r] ?? const {};
          if (cells.isEmpty) continue;
          buf.writeln([
            for (var c = 0; c < sh.cols; c++) cells[c]?.text ?? ''
          ].join(' | '));
        }
        texts.add(buf.toString());
      }
      if (mounted) {
        setState(() {
          _xlsxSheets = sheets;
          _officePageTexts = texts;
        });
      }
      _jumpWhenReady(
          widget.initialPage.clamp(0, math.max(sheets.length - 1, 0)));
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('表格解析失败：$e')));
      }
    }
  }

  Future<void> _loadPptx() async {
    try {
      final path = widget.entryId == null
          ? null
          : _libraryNotifier?.byId(widget.entryId!)?.path;
      if (path == null) throw '缺少文件路径';
      final bytes = await File(path).readAsBytes();
      final slides = parsePptxSlides(bytes);
      final texts = <String>[];
      for (final sl in slides) {
        texts.add(sl.boxes
            .expand((b) => b.paras)
            .map((p) => p.text)
            .join('\n'));
      }
      if (mounted) {
        setState(() {
          _pptxSlides = slides;
          _officePageTexts = texts;
        });
      }
      _jumpWhenReady(
          widget.initialPage.clamp(0, math.max(slides.length - 1, 0)));
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('演示文稿解析失败：$e')));
      }
    }
  }

  /// 漫画：读导入时落盘的页面图（manifest imgN 按编号排序）。
  Future<void> _loadComic() async {
    try {
      if (widget.entryId == null) throw '缺少条目';
      final support = await getApplicationSupportDirectory();
      final dir = '${support.path}/images/${widget.entryId}';
      final f = File('$dir/manifest.json');
      if (!f.existsSync()) throw '没有页面数据';
      final raw = jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
      final ids = raw.keys
          .where((k) => k.startsWith('img'))
          .map((k) => int.tryParse(k.substring(3)) ?? 0)
          .toList()
        ..sort();
      final pages = <({String path, int w, int h})>[];
      for (final n in ids) {
        final info = raw['img$n'];
        if (info is Map && info['file'] is String) {
          pages.add((
            path: '$dir/${info['file']}',
            w: (info['w'] as num?)?.toInt() ?? 0,
            h: (info['h'] as num?)?.toInt() ?? 0,
          ));
        }
      }
      if (mounted) {
        setState(() => _comicPages = pages);
      }
      _jumpWhenReady(
          widget.initialPage.clamp(0, math.max(pages.length - 1, 0)));
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('漫画加载失败：$e')));
      }
    }
  }

  Future<void> _load() async {
    final format = switch (widget.format) {
      'md' || 'xlsx' || 'pptx' || 'cbz' => DocFormat.md,
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
  /// PDF 原版渲染模式：阅读视图逐页 pdfium 渲染（图示/版式保真），
  /// 同时提取全文文字构建 _doc（仅供 Agent 工具 / 整页翻译 / 批注使用）。
  /// 页面图片按需渲染并缓存到 `images/<entryId>/pdfpN.png`。
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
      _pdfBookmarks = bookmarks;
      _pdfPageCount = pdf.pages.length;
      final support = await getApplicationSupportDirectory();
      _pdfImageDirPath = '${support.path}/images/${widget.entryId}';

      // 全文文字版 md：只给 Agent/翻译用，不用于阅读显示
      final md = StringBuffer();
      var bookmarkIdx = 0;
      for (var p = 1; p <= pdf.pages.length; p++) {
        while (bookmarkIdx < bookmarks.length &&
            bookmarks[bookmarkIdx].$2 <= p) {
          final (title, _, depth) = bookmarks[bookmarkIdx];
          final level = (depth + 1).clamp(1, 6);
          md.writeln('${'#' * level} $title');
          bookmarkIdx++;
        }
        if (bookmarks.isEmpty) md.writeln('# 第 $p 页');
        final rawText =
            (await pdf.pages[p - 1].loadText())?.fullText.trim() ?? '';
        _pdfPageTexts = [..._pdfPageTexts, rawText];
        if (rawText.isNotEmpty) md.writeln(rawText);
        md.writeln('');
      }
      // 长按选择面板 / 整页翻译共用（office 模式统一取文字层）
      _officePageTexts = _pdfPageTexts;

      await _loadPdfRenderCache();
      _pdfDoc = pdf;
      final doc = await PlainTextDocument.create(
          _docId, widget.title, DocFormat.md, md.toString());
      _currentPage = widget.initialPage.clamp(0, pdf.pages.length - 1);
      if (mounted) setState(() => _doc = doc);
      _jumpWhenReady(_currentPage);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('PDF 解析失败：$e')));
      }
    } finally {
      if (mounted) setState(() => _pdfLoading = false);
    }
  }

  String? _pdfImageDirPath; // images/<entryId>，_extractPdf 时确定
  String get _pdfImageDir => _pdfImageDirPath ?? '';

  /// 复用上次打开时已渲染的页面图（manifest.json 中 pdfp* 条目）。
  Future<void> _loadPdfRenderCache() async {
    if (widget.entryId == null) return;
    try {
      final f = File('$_pdfImageDir/manifest.json');
      if (!f.existsSync()) return;
      final raw = jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
      raw.forEach((id, info) {
        if (!id.startsWith('pdfp')) return;
        final page = int.tryParse(id.substring(4));
        final map = info as Map<String, dynamic>;
        if (page != null && map['file'] != null) {
          _pdfRendered[page] = (
            path: '$_pdfImageDir/${map['file']}',
            w: (map['w'] as num?)?.toInt() ?? 0,
            h: (map['h'] as num?)?.toInt() ?? 0,
          );
        }
      });
    } catch (_) {}
  }

  /// 渲染第 p 页（1-based）并落盘缓存；正在渲染中返回 null。
  Future<({String path, int w, int h})?> _renderPdfPage(int p) async {
    final cached = _pdfRendered[p];
    if (cached != null) return cached;
    if (_pdfRendering.contains(p) || _pdfDoc == null) return null;
    _pdfRendering.add(p);
    try {
      final page = _pdfDoc!.pages[p - 1];
      final png = await renderPdfPagePng(page);
      if (png == null) return null;
      Directory(_pdfImageDir).createSync(recursive: true);
      final f = File('$_pdfImageDir/pdfp$p.png');
      f.writeAsBytesSync(png);
      // 宽高从 PNG 头读取（IHDR：16-23 字节，大端）
      final w = (png[16] << 24) | (png[17] << 16) | (png[18] << 8) | png[19];
      final h = (png[20] << 24) | (png[21] << 16) | (png[22] << 8) | png[23];
      final result = (path: f.path, w: w, h: h);
      if (mounted) setState(() => _pdfRendered[p] = result);
      _savePdfRenderManifest(p, result);
      return result;
    } catch (_) {
      return null;
    } finally {
      _pdfRendering.remove(p);
    }
  }

  /// 渲染结果合并进 manifest.json（与 docx/epub 图片清单同目录同格式）。
  void _savePdfRenderManifest(int p, ({String path, int w, int h}) info) {
    try {
      final f = File('$_pdfImageDir/manifest.json');
      final raw = f.existsSync()
          ? jsonDecode(f.readAsStringSync()) as Map<String, dynamic>
          : <String, dynamic>{};
      raw['pdfp$p'] = {
        'file': 'pdfp$p.png',
        'w': info.w,
        'h': info.h,
      };
      f.writeAsStringSync(jsonEncode(raw));
    } catch (_) {}
  }

  /// 阅读视图渲染第 p 页（1-based）：优先用缓存，否则按需渲染。
  /// 缩放统一由外层 _PinchZoom（单页）/ Transform（连续）处理，页面不再自带 IV。
  Widget _buildPdfPage(int p, ReaderTheme theme, {bool interactive = false}) {
    Widget imageOf(({String path, int w, int h}) info) => InteractiveViewer(
          maxScale: 5.0,
          child: Center(
            child: Image.file(File(info.path), fit: BoxFit.contain),
          ),
        );
    Widget plainImage(({String path, int w, int h}) info) => Center(
          child: Image.file(File(info.path),
              fit: BoxFit.fill, width: double.infinity),
        );
    final info = _pdfRendered[p];
    if (info != null) return interactive ? imageOf(info) : plainImage(info);
    final future =
        _pdfFutures.putIfAbsent(p, () => _renderPdfPage(p));
    return FutureBuilder<({String path, int w, int h})?>(
      future: future,
      builder: (context, snap) {
        if (snap.hasData && snap.data != null) {
          WidgetsBinding.instance
              .addPostFrameCallback((_) => _preRenderNeighbors(p));
          return interactive ? imageOf(snap.data!) : plainImage(snap.data!);
        }
        if (snap.connectionState == ConnectionState.done) {
          // 渲染失败：重试
          return Center(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              const Icon(Icons.error_outline),
              Text('第 $p 页渲染失败',
                  style: TextStyle(color: theme.text, fontSize: 14)),
              TextButton(
                  onPressed: () {
                    setState(() => _pdfFutures.remove(p));
                  },
                  child: const Text('重试')),
            ]),
          );
        }
        return Center(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const CircularProgressIndicator(),
            const SizedBox(height: 8),
            Text('正在渲染第 $p 页…',
                style: TextStyle(color: theme.text, fontSize: 14)),
          ]),
        );
      },
    );
  }

  @override
  void dispose() {
    _saveProgress();
    _pageController.dispose();
    _continuousController.dispose();
    _pdfDoc?.dispose();
    // 恢复方向与系统 UI：手机回竖屏（横屏仅 ppt/xlsx 单页模式期间生效）；
    // 宽屏设备保持不锁方向，随用户旋转
    SystemChrome.setPreferredOrientations(_wideScreen
        ? const [
            DeviceOrientation.portraitUp,
            DeviceOrientation.landscapeLeft,
            DeviceOrientation.landscapeRight,
          ]
        : const [DeviceOrientation.portraitUp]);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    WakelockPlus.disable();
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
    final st = ref.read(readerSettingsProvider);
    final key = '$modeTag|$width x $height x $fontSize x ${st.lineHeight} x ${st.paraSpacing}';
    // ignore: avoid_print
    print('PAGDBG width=$width height=$height fontSize=$fontSize margin=${st.margin}');
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
            lineHeight: st.lineHeight,
            paragraphSpacing: st.paraSpacing,
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
      target = -1;
      if (widget.initialSection != null) {
        target = _pageForSection(doc, widget.initialSection!);
      }
      if (target < 0) {
        target = widget.initialPage.clamp(0, _pages.length - 1);
      }
      _jumped = true;
    }

    WidgetsBinding.instance.addPostFrameCallback((_) => _jumpWhenReady(target));
  }

  /// 含指定节的第一个分页页码（0 基）；找不到返回 -1。
  int _pageForSection(PlainTextDocument doc, int sectionIndex) {
    final sec = doc.sectionAt(sectionIndex);
    if (sec == null || sec.paragraphs.isEmpty) return -1;
    final para = sec.paragraphs.first.index;
    for (var i = 0; i < _pages.length; i++) {
      for (final line in _pages[i].lines) {
        if (line.paragraphIndex == para) return i;
      }
    }
    return -1;
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

  /// 确认编辑：只改动内存文档（文字层），退出阅读器时统一询问保存方式。
  Future<void> _applyEditing(PlainTextDocument doc) async {
    final s = AppLocalizations.of(context)!;
    final section = _editSection;
    final controller = _editController;
    if (section == null || controller == null) return;
    // 图片占位符保护：编辑可能把占位符并进正文段，强制独占一段
    final newText = ensureStandaloneImageLines(controller.text);
    await doc.applyEdit(DocTextEdit.replace(
      CharRange(section.charOffset, section.charOffset + section.charCount),
      '$newText\n\n',
    ));
    setState(() {
      _editing = false;
      _editController?.dispose();
      _editController = null;
      _editSection = null;
      _pendingEdits = true; // 有未落盘的修改
      _paginationKey = null;
    });
    if (mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(s.editCacheSaved)));
    }
  }

  /// 退出前的保存询问：另存 / 覆盖 / 放弃修改 / 继续编辑。
  Future<void> _exitWithSaveDialog() async {
    final s = AppLocalizations.of(context)!;
    final choice = await showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: Text(s.unsavedTitle),
        content: Text(_isPdf || _isXlsx || _isPptx
            ? s.exitSaveOffice
            : s.exitSaveText),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, 'continue'),
              child: Text(s.continueEditing)),
          TextButton(
              onPressed: () => Navigator.pop(context, 'discard'),
              child: Text(s.discardChanges)),
          TextButton(
              onPressed: () => Navigator.pop(context, 'export'),
              child: Text(s.saveAs)),
          FilledButton(
              onPressed: () => Navigator.pop(context, 'overwrite'),
              child: Text(s.overwrite)),
        ],
      ),
    );
    if (choice == 'continue' || choice == null) return;
    if (choice == 'discard') {
      _pendingEdits = false;
      if (mounted) Navigator.of(context).pop();
      return;
    }
    if (choice == 'export') {
      final doc = _doc;
      if (doc != null) {
        await _exportOrSaveDoc(doc, exportAs: true);
      }
      _pendingEdits = false;
      if (mounted) Navigator.of(context).pop();
      return;
    }
    // 覆盖
    final doc = _doc;
    if (doc != null && await _overwriteDoc(doc)) {
      _pendingEdits = false;
      if (mounted) Navigator.of(context).pop();
    }
  }

  /// 覆盖：txt/md/json 写回原文件(.bak)；office/pdf 存应用内编辑缓存。
  /// 返回是否成功（失败留在当前页让用户另存）。
  Future<bool> _overwriteDoc(PlainTextDocument doc) async {
    final out = widget.format == 'json'
        ? jsonEncode(doc.document.sections
            .map((sec) => {
                  'index': sec.index,
                  'title': sec.title,
                  'text': sec.plainText,
                })
            .toList())
        : doc.rawText;

    // office/pdf：应用内编辑缓存，之后打开优先使用
    if (!_writebackSupported) {
      try {
        final support = await getApplicationSupportDirectory();
        final cacheDir = Directory('${support.path}/edited');
        await cacheDir.create(recursive: true);
        final cacheFile = File('${cacheDir.path}/${_docId.hashCode.abs()}.md');
        await cacheFile.writeAsString(out, flush: true);
        if (widget.entryId != null) {
          await ref
              .read(libraryProvider.notifier)
              .updateMeta(widget.entryId!, editedPath: cacheFile.path);
        }
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('已覆盖保存到应用内编辑缓存')));
        }
        return true;
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context)
              .showSnackBar(SnackBar(content: Text('保存失败：$e')));
        }
        return false;
      }
    }

    // txt/md/json：写回原文件（先备份 .bak）
    try {
      String? targetPath = widget.entryId == null
          ? null
          : ref.read(libraryProvider.notifier).byId(widget.entryId!)?.path;
      if (targetPath == null) {
        final location = await getSaveLocation(
            suggestedName: '${doc.document.title}.${widget.format}');
        if (location == null) return false;
        targetPath = location.path;
      } else {
        final bytes = await XFile(targetPath).readAsBytes();
        await XFile.fromData(bytes).saveTo('$targetPath.bak');
      }
      await XFile.fromData(utf8.encode(out)).saveTo(targetPath);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('已写回 $targetPath（原文件备份 .bak）')));
      }
      return true;
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('写回失败：$e')));
      }
      return false;
    }
  }

  String _pageTextAt(int idx) {
    if (idx < 0 || idx >= _pages.length) return '';
    return _pages[idx]
        .lines
        .map((l) => l.segments.map((seg) => seg.text).join())
        .join('\n');
  }

  /// 跳到指定页（单页/连续各自处理）。
  void _jumpToPage(int idx) {
    if (idx < 0) return;
    if (_officeMode && _continuous) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!_scrollReady) return;
        double target;
        if (_contOffsets.length == _officePageCount + 1) {
          target = _contOffsets[idx.clamp(0, _officePageCount - 1)];
        } else {
          target = idx * _continuousController.position.viewportDimension;
        }
        _continuousController.jumpTo(
            math.min(target, _continuousController.position.maxScrollExtent));
      });
    } else {
      _jumpWhenReady(idx);
    }
  }

  /// PDF 相邻页预渲染：当前页完成后预取前后页，翻页即显。
  void _preRenderNeighbors(int p) {
    for (final n in [p - 1, p + 1]) {
      if (n >= 1 &&
          n <= _pdfPageCount &&
          !_pdfRendered.containsKey(n) &&
          !_pdfRendering.contains(n) &&
          !_pdfFutures.containsKey(n)) {
        _pdfFutures[n] = _renderPdfPage(n);
      }
    }
  }

  /// 阅读设置弹窗：主题/字号/行距/段距/边距/亮度/跳页/常亮/沉浸。
  void _showReadingSettingsSheet() {
    final s = AppLocalizations.of(context)!;
    var st = ref.read(readerSettingsProvider);
    final pageCount = _officeMode ? _officePageCount : _pages.length;
    var jumpValue = _currentPage.clamp(0, math.max(pageCount - 1, 0));
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (context) => StatefulBuilder(
        builder: (context, setSheet) {
          st = ref.read(readerSettingsProvider);
          final theme = ReaderTheme.presets
              [st.theme.clamp(0, ReaderTheme.presets.length - 1)];
          Widget label(String t, String v) => Padding(
              padding: const EdgeInsets.only(top: 10, bottom: 2),
              child: Row(children: [
                Text(t,
                    style: TextStyle(
                        fontSize: 13,
                        color: theme.text.withValues(alpha: 0.7))),
                const Spacer(),
                Text(v, style: TextStyle(fontSize: 13, color: theme.text)),
              ]));
          return Container(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Row(children: [
                Text(s.readingSettings,
                    style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                        color: theme.text)),
                const Spacer(),
                IconButton(
                    icon: Icon(Icons.close, size: 20, color: theme.text),
                    onPressed: () => Navigator.pop(context)),
              ]),
              Row(children: [
                Text(s.theme,
                    style: TextStyle(color: theme.text, fontSize: 14)),
                const Spacer(),
                for (var i = 0; i < ReaderTheme.presets.length; i++)
                  GestureDetector(
                    onTap: () {
                      ref.read(readerSettingsProvider.notifier).setTheme(i);
                      setSheet(() {});
                    },
                    child: Container(
                      margin: const EdgeInsets.only(left: 10),
                      width: 34,
                      height: 34,
                      decoration: BoxDecoration(
                          color: ReaderTheme.presets[i].background,
                          shape: BoxShape.circle,
                          border: Border.all(
                              color: st.theme == i
                                  ? Colors.teal
                                  : theme.text.withValues(alpha: 0.3),
                              width: st.theme == i ? 2.5 : 1)),
                      alignment: Alignment.center,
                      child: Text(ReaderTheme.presets[i].name,
                          style: TextStyle(
                              fontSize: 10,
                              color: ReaderTheme.presets[i].text)))),
              ]),
              label(s.fontSize, st.fontSize.toStringAsFixed(0)),
              Slider(
                value: st.fontSize,
                min: 12,
                max: 32,
                divisions: 20,
                label: st.fontSize.toStringAsFixed(0),
                onChanged: (v) {
                  ref.read(readerSettingsProvider.notifier).setFontSize(v);
                  setSheet(() {});
                },
              ),
              label(s.lineSpacing, st.lineHeight.toStringAsFixed(2)),
              Slider(
                value: st.lineHeight,
                min: 1.0,
                max: 2.4,
                divisions: 14,
                label: st.lineHeight.toStringAsFixed(2),
                onChanged: (v) {
                  ref.read(readerSettingsProvider.notifier).setLineHeight(v);
                  setSheet(() {});
                },
              ),
              label(s.paraSpacing, st.paraSpacing.toStringAsFixed(0)),
              Slider(
                value: st.paraSpacing,
                min: 0,
                max: 32,
                divisions: 16,
                label: st.paraSpacing.toStringAsFixed(0),
                onChanged: (v) {
                  ref.read(readerSettingsProvider.notifier).setParaSpacing(v);
                  setSheet(() {});
                },
              ),
              label(s.pageMargin, st.margin.toStringAsFixed(0)),
              Slider(
                value: st.margin,
                min: 0,
                max: 64,
                divisions: 16,
                label: st.margin.toStringAsFixed(0),
                onChanged: (v) {
                  ref.read(readerSettingsProvider.notifier).setMargin(v);
                  setSheet(() {});
                },
              ),
              label(s.brightness, '${(st.brightness * 100).toStringAsFixed(0)}%'),
              Slider(
                value: st.brightness,
                min: 0.05,
                max: 1.0,
                label: '${(st.brightness * 100).toStringAsFixed(0)}%',
                onChanged: (v) {
                  ref.read(readerSettingsProvider.notifier).setBrightness(v);
                  setSheet(() {});
                },
              ),
              if (pageCount > 1) ...[
                label(s.jumpToPage, '${jumpValue + 1} / $pageCount'),
                Slider(
                  value: jumpValue.toDouble(),
                  min: 0,
                  max: (pageCount - 1).toDouble(),
                  divisions: pageCount > 1 ? pageCount - 1 : null,
                  label: '${jumpValue + 1}',
                  onChanged: (v) =>
                      setSheet(() => jumpValue = v.round().clamp(0, pageCount - 1)),
                  onChangeEnd: (v) => _jumpToPage(v.round()),
                ),
              ],
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(s.keepAwake,
                    style: TextStyle(color: theme.text, fontSize: 14)),
                value: st.keepAwake,
                onChanged: (v) {
                  ref.read(readerSettingsProvider.notifier).setKeepAwake(v);
                  setSheet(() {});
                  _applyComfortSettings();
                },
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(s.immersiveMode,
                    style: TextStyle(color: theme.text, fontSize: 14)),
                value: st.immersive,
                onChanged: (v) {
                  ref.read(readerSettingsProvider.notifier).setImmersive(v);
                  setSheet(() {});
                  _applyComfortSettings();
                },
              ),
            ]),
          );
        },
      ),
    );
  }

  /// 全书搜索：文字格式按分页页，office 按文字层页；结果点击跳页。
  Future<void> _showSearch() async {
    final s = AppLocalizations.of(context)!;
    final query = await showDialog<String>(
      context: context,
      builder: (context) {
        final ctrl = TextEditingController();
        return AlertDialog(
          title: Text(s.search),
          content: TextField(
            autofocus: true,
            controller: ctrl,
            decoration: InputDecoration(hintText: s.searchHint),
            onSubmitted: (v) => Navigator.pop(context, v),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(context),
                child: Text(s.cancel)),
            FilledButton(
                onPressed: () => Navigator.pop(context, ctrl.text),
                child: Text(s.search)),
          ],
        );
      },
    );
    if (query == null) return;
    final q = query.trim();
    if (q.isEmpty) return;
    final qLower = q.toLowerCase();
    final total = _officeMode ? _officePageCount : _pages.length;
    final results = <(int, String)>[];
    for (var i = 0; i < total && results.length < 50; i++) {
      final raw = _officeMode
          ? (i < _officePageTexts.length ? _officePageTexts[i] : '')
          : _pageTextAt(i);
      final pos = raw.toLowerCase().indexOf(qLower);
      if (pos == -1) continue;
      final start = (pos - 20).clamp(0, raw.length);
      final end = (pos + q.length + 30).clamp(0, raw.length);
      final snippet =
          raw.substring(start, end).replaceAll('\n', ' ');
      results.add((i,
          '${start > 0 ? '…' : ''}$snippet${end < raw.length ? '…' : ''}'));
    }
    if (!mounted) return;
    showModalBottomSheet(
      context: context,
      builder: (context) => SafeArea(
        child: SizedBox(
          height: MediaQuery.of(context).size.height * 0.6,
          child: results.isEmpty
              ? Center(child: Text(s.noResults))
              : ListView.builder(
                  itemCount: results.length,
                  itemBuilder: (context, i) {
                    final (page, snippet) = results[i];
                    return ListTile(
                      dense: true,
                      leading: Text('${page + 1}',
                          style: const TextStyle(
                              fontWeight: FontWeight.bold,
                              color: Colors.teal)),
                      title: Text(snippet,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis),
                      onTap: () {
                        Navigator.pop(context);
                        _jumpToPage(page);
                      },
                    );
                  },
                ),
        ),
      ),
    );
  }

  /// 手势发生时刻的实时页码（避免用滞后/四舍五入到邻页的 _currentPage）。
  int _livePageIndex() {
    if (_officeMode && _continuous) {
      if (_continuousController.hasClients &&
          _contOffsets.length == _officePageCount + 1) {
        final off = _continuousController.offset;
        int lo = 0, hi = _officePageCount - 1, res = 0;
        while (lo <= hi) {
          final mid = (lo + hi) >> 1;
          if (_contOffsets[mid] <= off) {
            res = mid;
            lo = mid + 1;
          } else {
            hi = mid - 1;
          }
        }
        return res;
      }
      return _currentPage;
    }
    if (_pageController.hasClients && _pageController.page != null) {
      return _pageController.page!.round().clamp(0,
          math.max((_officeMode ? _officePageCount : _pages.length) - 1, 0));
    }
    return _currentPage;
  }

  /// 长按：本页文字选择面板（选择后可复制 / 翻译所选）。
  void _showTextSelectionSheet() {
    final s = AppLocalizations.of(context)!;
    final idx = _livePageIndex();
    String text = _officeMode
        ? (idx >= 0 && idx < _officePageTexts.length
            ? _officePageTexts[idx]
            : '')
        : _pageTextAt(idx);
    if (text.isEmpty) text = s.noPageText;
    _sheetSelection = null;
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (context) => StatefulBuilder(
        builder: (context, setSheet) => DraggableScrollableSheet(
          initialChildSize: 0.6,
          maxChildSize: 0.9,
          expand: false,
          builder: (context, scrollController) => Container(
            padding: const EdgeInsets.all(16),
            child: Column(children: [
              Row(children: [
                Text(s.pageTextTitle,
                    style: const TextStyle(
                        fontSize: 15, fontWeight: FontWeight.bold)),
                const Spacer(),
                IconButton(
                    icon: const Icon(Icons.close, size: 18),
                    onPressed: () => Navigator.pop(context)),
              ]),
              const Divider(),
              Row(children: [
                TextButton.icon(
                  icon: const Icon(Icons.copy, size: 16),
                  label: Text(s.copySelected),
                  onPressed: () {
                    final sel = _sheetSelection;
                    final t = sel == null
                        ? text
                        : text.substring(sel.start.clamp(0, text.length),
                            sel.end.clamp(0, text.length));
                    Clipboard.setData(ClipboardData(text: t));
                    ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('已复制')));
                  },
                ),
                const SizedBox(width: 8),
                TextButton.icon(
                  icon: const Icon(Icons.translate, size: 16),
                  label: Text(s.translateSelected),
                  onPressed: () {
                    final sel = _sheetSelection;
                    final t = sel == null
                        ? text
                        : text.substring(sel.start.clamp(0, text.length),
                            sel.end.clamp(0, text.length));
                    Navigator.pop(context);
                    final lang = PrefsService.instance.loadTargetLang();
                    _translateAndShow(t,
                        title: '所选文字 · ${targetLangName(lang)}',
                        targetLang: lang);
                  },
                ),
              ]),
              const Divider(),
              Expanded(
                child: SingleChildScrollView(
                  controller: scrollController,
                  child: SelectableText(text,
                      style: const TextStyle(fontSize: 15, height: 1.7),
                      onSelectionChanged: (sel, cause) {
                        if (sel.start != sel.end) {
                          _sheetSelection = sel;
                          setSheet(() {});
                        }
                      }),
                ),
              ),
            ]),
          ),
        ),
      ),
    );
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

  Future<void> _openTranslateMenu() async {
    final s = AppLocalizations.of(context)!;
    // 先选目标语言（记忆上次选择），再选翻译范围
    final langCode = await showDialog<String>(
      context: context,
      builder: (context) => SimpleDialog(
        title: Text(s.translateTo),
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

    // Office/漫画原版渲染模式：无选块，整页翻译用提取文字
    if (_officeMode) {
      final text = _currentPageOfficeText.trim();
      if (text.isEmpty) return;
      await _translateAndShow(text,
          title: '整页 · 第${_currentPage + 1}页 · $langName',
          targetLang: langCode);
      return;
    }

    final choice = await showDialog<String>(
      context: context,
      builder: (context) => SimpleDialog(
        title: Text('${s.translate} · $langName'),
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

  /// 连续阅读视图：按页面真实宽高比紧密堆叠（无页间空隙），
  /// 滚动时按累计偏移定位当前页；双指捏合对整体内容缩放平移。
  Widget _buildContinuousOffice(ReaderTheme theme) {
    return LayoutBuilder(builder: (context, constraints) {
      final w = constraints.maxWidth;
      final heights = [
        for (var i = 0; i < _officePageCount; i++) _contPageHeight(i, w)
      ];
      final offsets = <double>[0];
      for (final h in heights) {
        offsets.add(offsets.last + h);
      }
      _contOffsets = offsets;
      return Listener(
        onPointerDown: _onPinchDown,
        onPointerMove: _onPinchMove,
        onPointerUp: _onPinchUp,
        onPointerCancel: _onPinchUp,
        child: Transform(
          transform: Matrix4.identity()
            ..translateByDouble(_contPan.dx, _contPan.dy, 0.0, 1.0)
            ..scaleByDouble(_contZoom, _contZoom, 1.0, 1.0),
          alignment: Alignment.topCenter,
          child: ListView.builder(
            controller: _continuousController,
            itemCount: _officePageCount,
            itemBuilder: (context, i) => SizedBox(
              height: heights[i],
              child: _officePageWidget(i, theme),
            ),
          ),
        ),
      );
    });
  }

  /// 连续模式第 i 页的自然高度（宽度铺满，高度按宽高比）。
  double _contPageHeight(int i, double w) {
    if (_isPdf) {
      final p = _pdfDoc!.pages[i];
      return w * p.height / p.width;
    }
    if (_isComic) {
      final info = _comicPages[i];
      return (info.w > 0 && info.h > 0) ? w * info.h / info.w : w;
    }
    if (_isPptx) {
      final s = _pptxSlides![i];
      return w * s.hEmu / s.wEmu;
    }
    // xlsx：内容高 + 首页顶部留白（避开悬浮顶栏）
    return XlsxSheetView.contentHeight(_xlsxSheets![i]) + (i == 0 ? 64 : 0);
  }

  Widget _officePageWidget(int i, ReaderTheme theme) {
    if (_isPdf) {
      // 连续模式：整体缩放已由外层 Transform 处理，页面本身不再套 IV
      final info = _pdfRendered[i + 1];
      if (info != null) {
        return Image.file(File(info.path),
            fit: BoxFit.fill, width: double.infinity);
      }
      return _buildPdfPage(i + 1, theme, interactive: false);
    }
    if (_isComic) {
      return Image.file(File(_comicPages[i].path), fit: BoxFit.fill);
    }
    if (_isXlsx) {
      return Padding(
        padding: EdgeInsets.only(top: i == 0 ? 64 : 0),
        child: XlsxSheetView(sheet: _xlsxSheets![i], verticalScroll: false),
      );
    }
    return PptxSlideView(slide: _pptxSlides![i]);
  }

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(readerSettingsProvider);
    final theme = ReaderTheme
        .presets[settings.theme.clamp(0, ReaderTheme.presets.length - 1)];
    final s = AppLocalizations.of(context)!;
    final doc = _activeDoc;
    final selecting = _translateMode == _TranslateMode.block && !_officeMode;
    final isPdf = _isPdf;
    final pageCount = _officeMode ? _officePageCount : _pages.length;
    return PopScope(
      canPop: !_pendingEdits,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _pendingEdits) _exitWithSaveDialog();
      },
      child: Scaffold(
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
                  onLongPress:
                      (_editing || selecting) ? null : _showTextSelectionSheet,
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
                  child: _officeMode && _continuous
                      ? _buildContinuousOffice(theme)
                      : isPdf
                      ? PageView.builder(
                          controller: _pageController,
                          itemCount: _pdfPageCount,
                          onPageChanged: _onOfficePageChanged,
                          itemBuilder: (context, i) => _PinchZoom(
                            key: ValueKey('pdf$i'),
                            child: _buildPdfPage(i + 1, theme),
                          ),
                        )
                      : _isComic
                          ? PageView.builder(
                              controller: _pageController,
                              itemCount: _comicPages.length,
                              onPageChanged: _onOfficePageChanged,
                              itemBuilder: (context, i) => _PinchZoom(
                                key: ValueKey('cbz$i'),
                                child: Center(
                                  child: Image.file(File(_comicPages[i].path),
                                      fit: BoxFit.contain),
                                ),
                              ),
                            )
                          : _isXlsx
                              ? PageView.builder(
                                  controller: _pageController,
                                  itemCount: _xlsxSheets!.length,
                                  onPageChanged: _onOfficePageChanged,
                                  itemBuilder: (context, i) => SafeArea(
                                    child: Padding(
                                      // 顶栏悬浮在内容上方，留出头部空间
                                      padding: const EdgeInsets.only(top: 64),
                                      child: _PinchZoom(
                                        key: ValueKey('x$i'),
                                        child: XlsxSheetView(
                                            sheet: _xlsxSheets![i]),
                                      ),
                                    ),
                                  ),
                                )
                              : _isPptx
                                  ? PageView.builder(
                                      controller: _pageController,
                                      itemCount: _pptxSlides!.length,
                                      onPageChanged: _onOfficePageChanged,
                                      itemBuilder: (context, i) => _PinchZoom(
                                        key: ValueKey('p$i'),
                                        child: PptxSlideView(
                                            slide: _pptxSlides![i]),
                                      ),
                                    )
                                  : LayoutBuilder(builder: (context, constraints) {
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
                      padding: EdgeInsets.fromLTRB(settings.margin, 8,
                          settings.margin, 32),
                      child: PageView.builder(
                        controller: _pageController,
                        itemCount: _pages.length,
                        onPageChanged: (page) {
                          _currentPage = page;
                          setState(() {});
                          _saveProgress();
                        },
                        itemBuilder: (context, i) => _PinchZoom(
                          key: ValueKey('t$i'),
                          child: _buildPage(_pages[i],
                              theme: theme,
                              fontSize: settings.fontSize,
                              selecting: selecting),
                        ),
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
                      '${_currentPage + 1} / $pageCount',
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
                                } else if (_pendingEdits) {
                                  _exitWithSaveDialog();
                                } else {
                                  Navigator.of(context).pop();
                                }
                              }),
                          Expanded(
                            child: Text(
                                selecting
                                    ? '${s.translate}：${s.selectText}'
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
                              tooltip: s.export,
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
                              tooltip: s.cancel,
                              icon: Icon(Icons.close, color: theme.text),
                              onPressed: _cancelEditing,
                            ),
                          ] else if (!_isComic)
                            IconButton(
                              tooltip: _isPdf || _isXlsx || _isPptx
                                  ? s.editTextLayer
                                  : s.editSection,
                              icon:
                                  Icon(Icons.edit_outlined, color: theme.text),
                              onPressed: () => _startEditing(doc),
                            ),
                          if (!_editing &&
                              (isPdf ||
                                  _isXlsx ||
                                  _isPptx ||
                                  doc.document.sections.length > 1))
                            IconButton(
                              tooltip: s.chapters,
                              icon: Icon(Icons.menu_book, color: theme.text),
                              onPressed: () {
                                if (isPdf) {
                                  _showPdfChapterList();
                                } else if (_isXlsx) {
                                  _showOfficeChapterList(
                                      [for (final sh in _xlsxSheets!) sh.name]);
                                } else if (_isPptx) {
                                  _showOfficeChapterList([
                                    for (var i = 0; i < _pptxSlides!.length; i++)
                                      _pptxSlides![i].title ?? '幻灯片 ${i + 1}'
                                  ]);
                                } else {
                                  _showSectionList();
                                }
                              },
                            ),
                          if (!_editing && !_isComic)
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
                            tooltip: s.agentPanel,
                            icon: Icon(Icons.auto_awesome,
                                color: _agentVisible
                                    ? Colors.teal
                                    : theme.text),
                            onPressed: () =>
                                setState(() => _agentVisible = !_agentVisible),
                          ),
                          if (!_editing && _officeMode)
                            IconButton(
                              tooltip: _continuous ? s.singlePageMode : s.continuousMode,
                              icon: Icon(
                                  _continuous
                                      ? Icons.view_day_outlined
                                      : Icons.swap_vert,
                                  color: theme.text),
                              onPressed: _toggleContinuous,
                            ),
                          if (!_editing)
                            IconButton(
                              tooltip: s.search,
                              icon: Icon(Icons.search, color: theme.text),
                              onPressed: _showSearch,
                            ),
                          if (!_editing)
                            IconButton(
                              tooltip: s.readingSettings,
                              icon: Icon(Icons.tune, color: theme.text),
                              onPressed: _showReadingSettingsSheet,
                            ),
                          const SizedBox(width: 8),
                        ]),
                      ),
                    ),
                  ),
                ),
              if (_editing)
                // 就地编辑：无边框、同背景、同字号、同页边距——
                // 看起来就是原页面的文字变成了可编辑状态
                Positioned(
                  left: 0,
                  right: 0,
                  top: 110,
                  bottom: 0,
                  child: Material(
                    color: theme.background,
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 32),
                      child: TextField(
                        controller: _editController,
                        maxLines: null,
                        expands: true,
                        textAlignVertical: TextAlignVertical.top,
                        cursorColor: Colors.teal,
                        style: TextStyle(
                            color: theme.text,
                            fontSize: settings.fontSize,
                            height: 1.6),
                        decoration: const InputDecoration.collapsed(
                            hintText: ''),
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
              // 亮度遮罩：盖在最上层，不拦截触摸
              if (settings.brightness < 0.999)
                Positioned.fill(
                  child: IgnorePointer(
                    child: Container(
                        color: Colors.black
                            .withValues(alpha: 1 - settings.brightness)),
                  ),
                ),
            ]),
    ),
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
                style: TextStyle(
                    fontSize: fontSize,
                    color: theme.text,
                    height: ref.read(readerSettingsProvider).lineHeight),
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

  void _onOfficePageChanged(int page) {
    _currentPage = page;
    setState(() {});
    _saveProgress();
  }

  /// xlsx sheet / pptx slide 目录（标题列表，点击跳转）。
  void _showOfficeChapterList(List<String> titles) {
    showModalBottomSheet(
      context: context,
      builder: (context) => SafeArea(
        child: SizedBox(
          height: MediaQuery.of(context).size.height * 0.6,
          child: ListView.builder(
            itemCount: titles.length,
            itemBuilder: (context, i) => ListTile(
              dense: true,
              leading: const Icon(Icons.article_outlined, size: 18),
              title: Text(titles[i], maxLines: 1),
              onTap: () {
                Navigator.pop(context);
                _jumpWhenReady(i.clamp(0, _officePageCount - 1));
              },
            ),
          ),
        ),
      ),
    );
  }

  /// PDF 目录：书签列表（无书签则逐页列表），点击跳转对应页。
  void _showPdfChapterList() {
    final items = _pdfBookmarks.isNotEmpty
        ? _pdfBookmarks
            .map((b) => (title: b.$1, page: b.$2, depth: b.$3))
            .toList()
        : [
            for (var p = 1; p <= _pdfPageCount; p++)
              (title: '第 $p 页', page: p, depth: 0)
          ];
    showModalBottomSheet(
      context: context,
      builder: (context) => SafeArea(
        child: SizedBox(
          height: MediaQuery.of(context).size.height * 0.6,
          child: ListView.builder(
            itemCount: items.length,
            itemBuilder: (context, i) {
              final it = items[i];
              return ListTile(
                dense: true,
                contentPadding:
                    EdgeInsets.only(left: 16.0 + it.depth * 16.0, right: 16),
                title: Text(it.title,
                    maxLines: 1, overflow: TextOverflow.ellipsis),
                subtitle: Text('第 ${it.page} 页'),
                onTap: () {
                  Navigator.pop(context);
                  _jumpWhenReady((it.page - 1).clamp(0, _pdfPageCount - 1));
                },
              );
            },
          ),
        ),
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
}


/// 双指缩放/平移容器（单页模式用）：
/// 用 Listener 手动跟踪双指（不参与手势 arena），单指滑动翻页、点击翻页均不受影响；
/// 双指捏合缩放（1~5 倍），双指拖动平移（缩放后查看边缘）。
class _PinchZoom extends StatefulWidget {
  const _PinchZoom({super.key, required this.child});

  final Widget child;

  @override
  State<_PinchZoom> createState() => _PinchZoomState();
}

class _PinchZoomState extends State<_PinchZoom> {
  final Map<int, Offset> _ptrs = {};
  double _prevDist = 0;
  double _scale = 1;
  Offset _prevMid = Offset.zero;
  Offset _pan = Offset.zero;

  void _down(PointerEvent e) {
    _ptrs[e.pointer] = e.position;
    if (_ptrs.length == 2) {
      final v = _ptrs.values.toList();
      _prevDist = (v[0] - v[1]).distance;
      _prevMid = (v[0] + v[1]) / 2;
    }
  }

  void _move(PointerEvent e) {
    if (!_ptrs.containsKey(e.pointer)) return;
    _ptrs[e.pointer] = e.position;
    if (_ptrs.length != 2) return;
    final v = _ptrs.values.toList();
    final d = (v[0] - v[1]).distance;
    final mid = (v[0] + v[1]) / 2;
    if (_prevDist > 0) {
      _scale = (_scale * d / _prevDist).clamp(1.0, 5.0);
      final size = context.size ?? const Size(400, 800);
      final maxDx = size.width * (_scale - 1) / 2;
      final maxDy = size.height * (_scale - 1) / 2;
      _pan = Offset(
          (_pan.dx + mid.dx - _prevMid.dx).clamp(-maxDx, maxDx),
          (_pan.dy + mid.dy - _prevMid.dy).clamp(-maxDy, maxDy));
      if (_scale <= 1.01) _pan = Offset.zero;
      if (mounted) setState(() {});
    }
    _prevDist = d;
    _prevMid = mid;
  }

  void _up(PointerEvent e) {
    _ptrs.remove(e.pointer);
    _prevDist = 0;
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      onPointerDown: _down,
      onPointerMove: _move,
      onPointerUp: _up,
      onPointerCancel: _up,
      child: Transform(
        transform: Matrix4.identity()
          ..translateByDouble(_pan.dx, _pan.dy, 0.0, 1.0)
          ..scaleByDouble(_scale, _scale, 1.0, 1.0),
        alignment: Alignment.center,
        child: widget.child,
      ),
    );
  }
}
