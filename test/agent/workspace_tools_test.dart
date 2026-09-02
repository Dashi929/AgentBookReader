import 'package:flutter_test/flutter_test.dart';
import 'package:agent_book_reader/agent/llm_client.dart';
import 'package:agent_book_reader/agent/tools.dart';
import 'package:agent_book_reader/agent/workspace_tools.dart';
import 'package:agent_book_reader/core/controller/plain_text_document.dart';
import 'package:agent_book_reader/core/model/char_range.dart';
import 'package:agent_book_reader/infra/agent_repository.dart';
import 'package:agent_book_reader/infra/database.dart';
import 'package:drift/native.dart';

/// 无 sqlite3 的环境跳过 DB 相关断言。
AppDatabase? tryOpenDb() {
  try {
    return AppDatabase.forTesting(NativeDatabase.memory());
  } catch (_) {
    return null;
  }
}

Future<Map<String, WorkspaceDoc>> twoDocs() async {
  final a = await PlainTextDocument.create(
      'a', '书A', DocFormat.md, '# 第一章\nAlpha 的第一章\n\n# 第二章\nAlpha 的第二章');
  final b = await PlainTextDocument.create('b', '书B', DocFormat.txt, 'Beta 的内容');
  return {
    'a': WorkspaceDoc(id: 'a', title: '书A', controller: a, format: 'md'),
    'b': WorkspaceDoc(id: 'b', title: '书B', controller: b, format: 'txt'),
  };
}

void main() {
  test('list_documents 列出全部已加载文档', () async {
    final registry = WorkspaceToolRegistry(
        docs: await twoDocs(), db: AppDatabase.forTesting(NativeDatabase.memory()));
    final out = await registry.handle(
        ToolCall(id: 'c', name: 'list_documents', argumentsJson: '{}'));
    expect(out, contains('a｜书A'));
    expect(out, contains('b｜书B'));
  });

  test('read_section / get_outline 必须带有效 doc_id', () async {
    final registry = WorkspaceToolRegistry(
        docs: await twoDocs(), db: AppDatabase.forTesting(NativeDatabase.memory()));
    final outline = await registry.handle(ToolCall(
        id: 'c', name: 'get_outline', argumentsJson: '{"doc_id": "b"}'));
    expect(outline, contains('Beta'));
    final section = await registry.handle(ToolCall(
        id: 'c', name: 'read_section', argumentsJson: '{"doc_id": "a", "section_index": 1}'));
    expect(section, contains('第二章'));
    final bad = await registry.handle(ToolCall(
        id: 'c', name: 'read_section', argumentsJson: '{"doc_id": "x", "section_index": 0}'));
    expect(bad, startsWith('错误'));
  });

  test('search_text 不带 doc_id 时跨全部文档搜索', () async {
    final registry = WorkspaceToolRegistry(
        docs: await twoDocs(), db: AppDatabase.forTesting(NativeDatabase.memory()));
    final all = await registry.handle(ToolCall(
        id: 'c', name: 'search_text', argumentsJson: '{"query": "的"}'));
    expect(all, contains('书A'));
    expect(all, contains('书B'));
    final one = await registry.handle(ToolCall(
        id: 'c', name: 'search_text', argumentsJson: '{"query": "Beta", "doc_id": "b"}'));
    expect(one, isNot(contains('书A')));
  });

  test('add_annotation 写入对应 docId（需要 sqlite3）', () async {
    final db = tryOpenDb();
    if (db == null) return;
    final registry = WorkspaceToolRegistry(docs: await twoDocs(), db: db);
    final result = await registry.handle(ToolCall(
        id: 'c',
        name: 'add_annotation',
        argumentsJson: '{"doc_id": "b", "section_index": 0, "note": "跨文档批注"}'));
    expect(result, contains('书B'));
    expect((await AgentRepository(db).annotationsFor('b')).length, 1);
    expect((await AgentRepository(db).annotationsFor('a')).length, 0);
    await db.close();
  });

  test('propose_rewrite 事件带回 docId', () async {
    RewriteProposal? proposal;
    String? proposalDocId;
    final registry = WorkspaceToolRegistry(
      docs: await twoDocs(),
      db: AppDatabase.forTesting(NativeDatabase.memory()),
      onProposal: (docId, p) {
        proposalDocId = docId;
        proposal = p;
      },
    );
    final result = await registry.handle(ToolCall(
        id: 'c',
        name: 'propose_rewrite',
        argumentsJson:
            '{"doc_id": "a", "find_text": "第一章", "new_text": "终章", "description": "改名"}'));
    expect(result, contains('提案已生成'));
    expect(proposalDocId, 'a');
    expect(proposal!.edit.newText, '终章');
  });
}
