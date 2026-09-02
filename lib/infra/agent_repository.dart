import 'package:drift/drift.dart';

import '../agent/llm_client.dart';
import '../core/model/annotation.dart';
import '../core/model/char_range.dart';
import 'database.dart' hide Document, Annotation;

/// Agent 会话/消息与批注的 DB 访问封装。
class AgentRepository {
  AgentRepository(this._db);
  final AppDatabase _db;

  Future<String> ensureSession(String? docId) async {
    final existing = await (_db.select(_db.agentSessions)
          ..where((s) =>
              docId == null ? s.docId.isNull() : s.docId.equals(docId)))
        .get();
    if (existing.isNotEmpty) return existing.last.id;
    final id = 'sess_${DateTime.now().microsecondsSinceEpoch}';
    await _db.into(_db.agentSessions).insert(AgentSessionsCompanion.insert(
          id: id,
          docId: Value(docId),
          createdAt: DateTime.now(),
        ));
    return id;
  }

  Future<List<AgentMessage>> messages(String sessionId) {
    return (_db.select(_db.agentMessages)
          ..where((m) => m.sessionId.equals(sessionId))
          ..orderBy([(m) => OrderingTerm.asc(m.createdAt)]))
        .get();
  }

  Future<void> appendMessage({
    required String sessionId,
    required String role,
    required String content,
    String? toolCallsJson,
  }) async {
    await _db.into(_db.agentMessages).insert(AgentMessagesCompanion.insert(
          id: 'msg_${DateTime.now().microsecondsSinceEpoch}_$role',
          sessionId: sessionId,
          role: role,
          content: content,
          toolCallsJson: Value(toolCallsJson),
          createdAt: DateTime.now(),
        ));
  }

  Future<void> clearSession(String sessionId) async {
    await (_db.delete(_db.agentMessages)
          ..where((m) => m.sessionId.equals(sessionId)))
        .go();
  }

  Future<List<Annotation>> annotationsFor(String docId) async {
    final rows = await (_db.select(_db.annotations)
          ..where((a) => a.docId.equals(docId))
          ..orderBy([(a) => OrderingTerm.desc(a.createdAt)]))
        .get();
    return rows
        .map((r) => Annotation(
              id: r.id,
              docId: r.docId,
              range: CharRange(r.rangeStart, r.rangeEnd),
              kind: AnnotationKind.values[r.kind.clamp(0, 2)],
              originalText: r.originalText,
              content: r.content,
              createdAt: r.createdAt,
            ))
        .toList();
  }

  /// 载入可回放给 LLM 的历史（仅 user/assistant 文本；工具中间过程不回放）。
  Future<List<LlmMessage>> loadLlmHistory(String sessionId) async {
    final rows = await messages(sessionId);
    return rows
        .where((r) => r.role == 'user' || r.role == 'assistant')
        .map((r) => r.role == 'user'
            ? LlmMessage.user(r.content)
            : LlmMessage.assistant(r.content))
        .toList();
  }
}
