import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:flutter/material.dart' show Color;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../infra/database.dart';

/// 轻量持久化（阅读设置等小配置；书架已迁 drift）。
class PrefsService {
  PrefsService._(this.sp);
  final SharedPreferences sp;

  static PrefsService? _instance;
  static PrefsService get instance => _instance!;

  static Future<void> init() async {
    _instance ??= PrefsService._(await SharedPreferences.getInstance());
  }

  int loadThemeIndex() => sp.getInt('readerTheme') ?? 1; // 默认护眼
  void saveThemeIndex(int i) => sp.setInt('readerTheme', i);
  double loadFontSize() => sp.getDouble('fontSize') ?? 18;
  void saveFontSize(double v) => sp.setDouble('fontSize', v);

  /// 翻译服务（llm | mymemory | google）
  String loadTranslationProvider() => sp.getString('translateProvider') ?? 'llm';
  void saveTranslationProvider(String id) => sp.setString('translateProvider', id);

  /// 翻译目标语言（zh/en/ja/ko/fr/de/es/ru）
  String loadTargetLang() => sp.getString('targetLang') ?? 'zh';
  void saveTargetLang(String code) => sp.setString('targetLang', code);

  /// 书架视图：true=网格（封面块状），false=列表
  bool loadLibraryView() => sp.getBool('libraryGridView') ?? false;
  void saveLibraryView(bool grid) => sp.setBool('libraryGridView', grid);
}

/// 支持的翻译目标语言（code, 显示名）。
const List<(String, String)> targetLanguages = [
  ('zh', '简体中文'),
  ('en', 'English'),
  ('ja', '日本語'),
  ('ko', '한국어'),
  ('fr', 'Français'),
  ('de', 'Deutsch'),
  ('es', 'Español'),
  ('ru', 'Русский'),
];

String targetLangName(String code) =>
    targetLanguages.firstWhere((e) => e.$1 == code, orElse: () => (code, code)).$2;

/// 书架条目。
class BookEntry {
  BookEntry({
    required this.id,
    required this.title,
    required this.path,
    required this.extension,
    this.author = '',
    this.synopsis = '',
    this.coverPath = '',
    this.lastPage = 0,
  });

  final String id;
  final String title;
  final String path;
  final String extension; // txt | md | json | docx | epub | pdf
  String author; // 空表示未知，可由 AI 补全
  String synopsis;
  String coverPath; // 封面图片路径；空表示用生成式占位封面
  int lastPage;
}

/// 书架状态（drift 持久化）。
class LibraryNotifier extends StateNotifier<List<BookEntry>> {
  LibraryNotifier(this._db) : super(const []) {
    _init();
  }

  final AppDatabase _db;
  static bool _migrated = false;

  Future<void> _init() async {
    // 一次性迁移：SharedPreferences 书架 → DB
    if (!_migrated) {
      _migrated = true;
      final sp = PrefsService.instance.sp;
      final raw = sp.getString('library');
      if (raw != null) {
        try {
          final list = (jsonDecode(raw) as List)
              .map((e) => Map<String, String>.from(e as Map))
              .toList();
          for (final m in list) {
            await _db.into(_db.documents).insertOnConflictUpdate(DocumentsCompanion.insert(
                  id: m['id']!,
                  title: m['title']!,
                  path: m['path'] ?? '',
                  format: m['ext'] ?? 'txt',
                  lastPage: Value(int.tryParse(m['lastPage'] ?? '0') ?? 0),
                  importedAt: DateTime.now(),
                ));
          }
          await sp.remove('library');
        } catch (_) {
          // 迁移失败不影响使用
        }
      }
    }

    final rows = await (_db.select(_db.documents)
          ..orderBy([(u) => OrderingTerm.desc(u.importedAt)]))
        .get();
    state = rows
        .map((r) => BookEntry(
              id: r.id,
              title: r.title,
              path: r.path,
              extension: r.format,
              author: r.author,
              synopsis: r.synopsis,
              coverPath: r.coverPath,
              lastPage: r.lastPage,
            ))
        .toList();
  }

  Future<void> add(BookEntry entry) async {
    await _db.into(_db.documents).insertOnConflictUpdate(DocumentsCompanion.insert(
          id: entry.id,
          title: entry.title,
          path: entry.path,
          format: entry.extension,
          author: Value(entry.author),
          synopsis: Value(entry.synopsis),
          coverPath: Value(entry.coverPath),
          lastPage: Value(entry.lastPage),
          importedAt: DateTime.now(),
        ));
    state = [entry, ...state.where((e) => e.id != entry.id)];
  }

  Future<void> remove(String id) async {
    await (_db.delete(_db.documents)..where((u) => u.id.equals(id))).go();
    state = state.where((e) => e.id != id).toList();
  }

  Future<void> updateLastPage(String id, int page) async {
    await (_db.update(_db.documents)..where((u) => u.id.equals(id)))
        .write(DocumentsCompanion(lastPage: Value(page)));
    state = [
      for (final e in state)
        if (e.id == id) e..lastPage = page else e
    ];
  }

  /// 元数据更新（作者/简介/封面），任一传 null 表示不改。
  Future<void> updateMeta(String id,
      {String? author, String? synopsis, String? coverPath}) async {
    await (_db.update(_db.documents)..where((u) => u.id.equals(id))).write(
        DocumentsCompanion(
            author: author == null ? const Value.absent() : Value(author),
            synopsis:
                synopsis == null ? const Value.absent() : Value(synopsis),
            coverPath:
                coverPath == null ? const Value.absent() : Value(coverPath)));
    state = [
      for (final e in state)
        if (e.id == id)
          e
            ..author = author ?? e.author
            ..synopsis = synopsis ?? e.synopsis
            ..coverPath = coverPath ?? e.coverPath
        else
          e
    ];
  }

  BookEntry? byId(String id) {
    for (final e in state) {
      if (e.id == id) return e;
    }
    return null;
  }
}

final appDatabaseProvider = Provider<AppDatabase>(
    (ref) => throw UnimplementedError('在 main.dart 中 override'));

final libraryProvider =
    StateNotifierProvider<LibraryNotifier, List<BookEntry>>(
        (ref) => LibraryNotifier(ref.watch(appDatabaseProvider)));

/// 阅读主题（0 白 / 1 护眼米黄 / 2 夜间）。
class ReaderTheme {
  const ReaderTheme(this.background, this.text, this.name);
  final Color background;
  final Color text;
  final String name;

  static const List<ReaderTheme> presets = [
    ReaderTheme(Color(0xFFFFFFFF), Color(0xFF222222), '白'),
    ReaderTheme(Color(0xFFF5EFDC), Color(0xFF3B3229), '护眼'),
    ReaderTheme(Color(0xFF1B1B1F), Color(0xFFB8BDC4), '夜间'),
  ];
}

class ReaderSettingsNotifier
    extends StateNotifier<({int theme, double fontSize})> {
  ReaderSettingsNotifier()
      : super((
          theme: PrefsService.instance.loadThemeIndex(),
          fontSize: PrefsService.instance.loadFontSize(),
        ));

  void setTheme(int i) {
    PrefsService.instance.saveThemeIndex(i);
    state = (theme: i, fontSize: state.fontSize);
  }

  void setFontSize(double v) {
    PrefsService.instance.saveFontSize(v);
    state = (theme: state.theme, fontSize: v);
  }
}

final readerSettingsProvider = StateNotifierProvider<ReaderSettingsNotifier,
    ({int theme, double fontSize})>((ref) => ReaderSettingsNotifier());
