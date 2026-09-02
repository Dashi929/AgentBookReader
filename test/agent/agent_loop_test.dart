import 'package:flutter_test/flutter_test.dart';
import 'package:agent_book_reader/agent/agent_loop.dart';
import 'package:agent_book_reader/agent/llm_client.dart';
import 'package:agent_book_reader/agent/tools.dart';
import 'package:agent_book_reader/core/controller/plain_text_document.dart';
import 'package:agent_book_reader/core/model/char_range.dart';
import 'package:agent_book_reader/infra/agent_repository.dart';
import 'package:agent_book_reader/infra/database.dart';
import 'package:drift/native.dart';

/// 假 LLM：按脚本回放响应。
class FakeLlmClient implements LlmClient {
  FakeLlmClient(this.script);
  final List<LlmResponse> script;
  var cursor = 0;

  @override
  Future<LlmResponse> chat({
    required List<LlmMessage> messages,
    List<LlmToolSpec>? tools,
    double temperature = 0.7,
  }) async {
    if (cursor >= script.length) {
      return const LlmResponse(content: '脚本耗尽', toolCalls: []);
    }
    return script[cursor++];
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// 无 sqlite3 的环境跳过 DB 相关断言（脚本仍验证工具循环本身）。
AppDatabase? tryOpenDb() {
  try {
    return AppDatabase.forTesting(NativeDatabase.memory());
  } catch (_) {
    return null;
  }
}

void main() {
  test('Agent 循环：无工具调用 → 直接返回文本', () async {
    final registry = AgentToolRegistry(
      controller: await PlainTextDocument.create(
          'd', '书', DocFormat.txt, '内容'),
      db: AppDatabase.forTesting(NativeDatabase.memory()),
      docId: 'd',
    );
    final loop = AgentLoop(
        client: FakeLlmClient([
          const LlmResponse(content: '答案', toolCalls: []),
        ]),
        registry: registry);
    final reply = await loop.run([LlmMessage.user('问题')]);
    expect(reply, '答案');
  });

  test('Agent 循环：工具调用 → 回填结果 → 第二轮给最终答案', () async {
    final doc = await PlainTextDocument.create(
        'd', '书', DocFormat.txt, '第一节内容\n\n第二节内容');
    final db = tryOpenDb();
    final registry = AgentToolRegistry(
        controller: doc, db: db ?? _NoopDb(), docId: 'd');
    final events = <String>[];
    final loop = AgentLoop(
      client: FakeLlmClient([
        const LlmResponse(content: null, toolCalls: [
          ToolCall(id: 'c1', name: 'get_outline', argumentsJson: '{}'),
        ]),
        const LlmResponse(content: '大纲已读，结论是…', toolCalls: []),
      ]),
      registry: registry,
      onEvent: (e) => events.add(e.runtimeType.toString()),
    );
    final reply = await loop.run([LlmMessage.user('这本书讲了什么')]);

    expect(reply, '大纲已读，结论是…');
    expect(events, ['AgentToolCallEvent', 'AgentToolResultEvent']);
    if (db != null) await db.close();
  });

  test('add_annotation 写入（需要 sqlite3）', () async {
    final db = tryOpenDb();
    if (db == null) {
      // 环境无 sqlite3.dll 时跳过（CI/打包自测由应用内验证）
      return;
    }
    final doc = await PlainTextDocument.create(
        'd', '书', DocFormat.txt, '第一段');
    final registry = AgentToolRegistry(
        controller: doc, db: db, docId: 'd');
    final result = await registry.handle(ToolCall(
        id: 'c',
        name: 'add_annotation',
        argumentsJson: '{"section_index": 0, "note": "要点"}'));
    expect(result, contains('已为第 0 节'));
    final anns = await AgentRepository(db).annotationsFor('d');
    expect(anns.length, 1);
    expect(anns.first.content, '要点');
    await db.close();
  });

  test('propose_rewrite：命中原文并产生提案', () async {
    final doc = await PlainTextDocument.create(
        'd', '书', DocFormat.txt, '旧句子在这里');
    RewriteProposal? got;
    final registry = AgentToolRegistry(
        controller: doc,
        db: AppDatabase.forTesting(NativeDatabase.memory()),
        docId: 'd',
        onProposal: (p) => got = p);
    final result = await registry.handle(ToolCall(
        id: 'c',
        name: 'propose_rewrite',
        argumentsJson:
            '{"find_text": "旧句子", "new_text": "新句子", "description": "优化措辞"}'));
    expect(result, contains('提案已生成'));
    expect(got, isNotNull);
    expect(got!.edit.newText, '新句子');
  });
}

class _NoopDb implements AppDatabase {
  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}
