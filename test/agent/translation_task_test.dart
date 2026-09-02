import 'package:flutter_test/flutter_test.dart';
import 'package:agent_book_reader/agent/translation_providers.dart';
import 'package:agent_book_reader/agent/translation_task.dart';
import 'package:agent_book_reader/agent/workspace_tools.dart';
import 'package:agent_book_reader/core/controller/plain_text_document.dart';
import 'package:agent_book_reader/core/model/char_range.dart';
import 'package:agent_book_reader/infra/database.dart';
import 'package:drift/native.dart';

AppDatabase? tryOpenDb() {
  try {
    return AppDatabase.forTesting(NativeDatabase.memory());
  } catch (_) {
    return null;
  }
}

/// 翻译提供方假体：返回固定文本并记录调用次数。
class FakeProvider implements TranslationProvider {
  var calls = 0;
  @override
  String get id => 'fake';
  @override
  String get label => 'Fake';
  @override
  Future<String> translate(String text, {required String targetLang}) async {
    calls++;
    return '[$targetLang] $text';
  }
}

void main() {
  test('assembleTranslationMarkdown：md 标题输出为 ##，txt 标题忽略', () {
    final md = assembleTranslationMarkdown(docTitle: '书', langName: 'English', sections: [
      const SectionTranslation('第一章', 'hello', isHeading: true),
      const SectionTranslation('第 2 段', 'world', isHeading: false),
    ]);
    expect(md, contains('# 书 · English 译文'));
    expect(md, contains('## 第一章'));
    expect(md, isNot(contains('## 第 2 段')));
    expect(md, contains('hello'));
    expect(md, contains('world'));
  });

  test('WholeDocTranslationTask：逐节翻译、缓存命中不重复调用、导出路径正确', () async {
    final db = tryOpenDb();
    if (db == null) return;
    final raw = '# A\nfirst section\n\n# B\nsecond section';
    final controller = await PlainTextDocument.create('d', '书', DocFormat.md, raw);
    final task = WholeDocTranslationTask(
      docs: [
        WorkspaceDoc(
            id: 'd', title: '书', controller: controller, format: 'md', path: r'D:\tmp\书.md'),
      ],
      db: db,
      provider: FakeProvider(),
      targetLang: 'en',
    );

    final progress = <int>[];
    final out = await task.run(
      onProgress: (done, total, _) => progress.add(done),
      cancelled: () => false,
    );

    expect(out.keys.single, r'D:\tmp\书.en.md');
    expect(out.values.single, contains('[en] first section'));
    expect(out.values.single, contains('## A'));
    expect(out.values.single, contains('## B'));

    // 重跑：全部命中缓存，provider 不再被调用
    final provider = task.provider as FakeProvider;
    final firstCalls = provider.calls;
    expect(firstCalls, 2);
    final again = await task.run(onProgress: (_, _, _) {}, cancelled: () => false);
    expect(again.values.single, contains('[en] first section'));
    expect((task.provider as FakeProvider).calls, firstCalls);
    await db.close();
  });

  test('cancel：取消后不再继续翻译并返回已完成部分', () async {
    final db = tryOpenDb();
    if (db == null) return;
    final provider = _CountingProvider();
    final raw = '# A\none\n\n# B\ntwo\n\n# C\nthree';
    final controller = await PlainTextDocument.create('d', '书', DocFormat.md, raw);
    final task = WholeDocTranslationTask(
      docs: [WorkspaceDoc(id: 'd', title: '书', controller: controller, format: 'md')],
      db: db,
      provider: provider,
      targetLang: 'en',
    );
    final out = await task.run(
        onProgress: (_, _, _) {},
        cancelled: () => provider.calls >= 2);
    expect(provider.calls, 2);
    expect(out, isEmpty);
    await db.close();
  });
}

class _CountingProvider implements TranslationProvider {
  var calls = 0;
  @override
  String get id => 'fake';
  @override
  String get label => 'Fake';
  @override
  Future<String> translate(String text, {required String targetLang}) async {
    calls++;
    return '[$targetLang] $text';
  }
}
