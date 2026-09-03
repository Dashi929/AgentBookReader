import 'package:drift/drift.dart';
import 'package:drift_flutter/drift_flutter.dart';

part 'database.g.dart';

/// 书架文档。
class Documents extends Table {
  TextColumn get id => text()();
  TextColumn get title => text()();
  TextColumn get path => text()();
  TextColumn get format => text()();
  TextColumn get author => text().withDefault(const Constant(''))();
  TextColumn get synopsis => text().withDefault(const Constant(''))();
  TextColumn get coverPath => text().withDefault(const Constant(''))();
  TextColumn get editedPath => text().withDefault(const Constant(''))();
  IntColumn get lastPage => integer().withDefault(const Constant(0))();
  DateTimeColumn get importedAt => dateTime()();

  @override
  Set<Column> get primaryKey => {id};
}

/// 批注/高亮/Agent 改写（M5 启用）。
class Annotations extends Table {
  TextColumn get id => text()();
  TextColumn get docId => text()();
  IntColumn get rangeStart => integer()();
  IntColumn get rangeEnd => integer()();
  IntColumn get kind => integer()();
  TextColumn get originalText => text()();
  TextColumn get content => text()();
  DateTimeColumn get createdAt => dateTime()();

  @override
  Set<Column> get primaryKey => {id};
}

/// Agent 会话（M4 启用）。
class AgentSessions extends Table {
  TextColumn get id => text()();
  TextColumn get docId => text().nullable()();
  DateTimeColumn get createdAt => dateTime()();

  @override
  Set<Column> get primaryKey => {id};
}

/// Agent 消息（M4 启用）。
class AgentMessages extends Table {
  TextColumn get id => text()();
  TextColumn get sessionId => text()();
  TextColumn get role => text()(); // user | assistant | tool
  TextColumn get content => text()();
  TextColumn get toolCallsJson => text().nullable()();
  DateTimeColumn get createdAt => dateTime()();

  @override
  Set<Column> get primaryKey => {id};
}

/// 整本翻译结果（M6 启用）：原文按 Section 对应存储，原文永不覆盖。
class Translations extends Table {
  TextColumn get docId => text()();
  IntColumn get sectionIndex => integer()();
  TextColumn get lang => text()();
  TextColumn get content => text()();
  DateTimeColumn get updatedAt => dateTime()();

  @override
  Set<Column> get primaryKey => {docId, sectionIndex, lang};
}

@DriftDatabase(
    tables: [Documents, Annotations, AgentSessions, AgentMessages, Translations])
class AppDatabase extends _$AppDatabase {
  AppDatabase() : super(_open());

  /// 测试用：内存数据库。
  AppDatabase.forTesting(super.e);

  @override
  int get schemaVersion => 3;

  @override
  MigrationStrategy get migration => MigrationStrategy(onUpgrade: (m, from, to) async {
        if (from < 2) {
          await m.addColumn(documents, documents.author);
          await m.addColumn(documents, documents.synopsis);
          await m.addColumn(documents, documents.coverPath);
        }
        if (from < 3) {
          await m.addColumn(documents, documents.editedPath);
        }
      });

  static QueryExecutor _open() => driftDatabase(name: 'agent_book_reader');
}
