import '../core/controller/plain_text_document.dart';
import '../core/model/annotation.dart';
import '../core/model/char_range.dart';
import '../infra/database.dart';
import 'llm_client.dart';
import 'tools.dart';

/// 工作台内单个已加载文档的条目。
class WorkspaceDoc {
  const WorkspaceDoc({
    required this.id,
    required this.title,
    required this.controller,
    required this.format,
    this.path,
  });
  final String id;
  final String title;
  final PlainTextDocument controller;

  /// 内容格式（txt/md/json；docx/epub 提取后按 md 处理）。
  final String format;

  /// 原文件路径（导出译文到同目录时使用）。
  final String? path;
}

/// Agent 工作台工具注册表：可同时挂载多个文档，工具均带 docId 参数。
/// 与阅读器内的 AgentToolRegistry（仅当前文档）相互独立。
class WorkspaceToolRegistry implements AgentToolHandler {
  WorkspaceToolRegistry({
    required this.docs,
    required this.db,
    this.onProposal,
  });

  /// docId → 文档条目。
  final Map<String, WorkspaceDoc> docs;
  final AppDatabase db;
  final void Function(String docId, RewriteProposal proposal)? onProposal;

  WorkspaceDoc? _doc(String? docId) {
    if (docId == null || docId.isEmpty) {
      return docs.length == 1 ? docs.values.first : null;
    }
    return docs[docId];
  }

  String get _docListHint => docs.isEmpty
      ? '（尚未加载任何文档）'
      : '可用文档：${docs.entries.map((e) => '${e.key}=${e.value.title}').join('；')}';

  @override
  final List<LlmToolSpec> specs = [
    const LlmToolSpec('list_documents', '列出工作台中已加载的所有文档（id 与标题）', {
      'type': 'object',
      'properties': {},
    }),
    const LlmToolSpec('get_outline', '获取某文档的大纲（各节标题与字数）', {
      'type': 'object',
      'properties': {
        'doc_id': {'type': 'string', 'description': '文档 id（list_documents 可查）'},
      },
      'required': ['doc_id'],
    }),
    const LlmToolSpec('read_section', '按序号读取某文档一节的全文文本', {
      'type': 'object',
      'properties': {
        'doc_id': {'type': 'string'},
        'section_index': {'type': 'integer', 'description': '节序号，从 0 开始'},
      },
      'required': ['doc_id', 'section_index'],
    }),
    const LlmToolSpec('search_text', '在某文档（或缺省时全部文档）中搜索关键词', {
      'type': 'object',
      'properties': {
        'query': {'type': 'string'},
        'doc_id': {'type': 'string', 'description': '可选；缺省搜索所有文档'},
      },
      'required': ['query'],
    }),
    const LlmToolSpec('add_annotation', '为某文档的某一节添加批注（写入数据库）', {
      'type': 'object',
      'properties': {
        'doc_id': {'type': 'string'},
        'section_index': {'type': 'integer'},
        'note': {'type': 'string', 'description': '批注内容'},
      },
      'required': ['doc_id', 'section_index', 'note'],
    }),
    const LlmToolSpec('propose_rewrite', '对某文档中的文字提出改写提案（需用户确认后生效）', {
      'type': 'object',
      'properties': {
        'doc_id': {'type': 'string'},
        'find_text': {'type': 'string', 'description': '要替换的原文片段（必须与原文完全一致）'},
        'new_text': {'type': 'string', 'description': '改写后的文本'},
        'description': {'type': 'string', 'description': '提案说明'},
      },
      'required': ['doc_id', 'find_text', 'new_text'],
    }),
  ];

  @override
  Future<String> handle(ToolCall call) async {
    final args = call.arguments;
    switch (call.name) {
      case 'list_documents':
        if (docs.isEmpty) return _docListHint;
        return docs.entries
            .map((e) => '${e.key}｜${e.value.title}｜${e.value.controller.sectionCount} 节｜'
                '${e.value.controller.charCount} 字')
            .join('\n');

      case 'get_outline':
        final d = _doc(args['doc_id'] as String?);
        if (d == null) return '错误：doc_id 无效。$_docListHint';
        final lines = <String>[];
        for (final s in d.controller.document.sections) {
          lines.add('${s.index}: ${s.title} (${s.charCount} 字)');
        }
        return lines.isEmpty ? '文档为空' : lines.join('\n');

      case 'read_section':
        final d = _doc(args['doc_id'] as String?);
        if (d == null) return '错误：doc_id 无效。$_docListHint';
        final idx = (args['section_index'] as num?)?.toInt() ?? -1;
        final s = d.controller.sectionAt(idx);
        if (s == null) return '错误：节 $idx 不存在（共 ${d.controller.sectionCount} 节）';
        var text = s.plainText;
        if (text.length > 6000) {
          text = '${text.substring(0, 6000)}\n…（截断，可继续用 search_text 定位）';
        }
        return '《${d.title}》第 $idx 节「${s.title}」：\n$text';

      case 'search_text':
        final q = args['query'] as String? ?? '';
        if (q.isEmpty) return '错误：query 为空';
        final target = args['doc_id'] as String?;
        final docs0 = target != null
            ? [if (docs[target] != null) docs[target]!]
            : docs.values.toList();
        if (docs0.isEmpty) return '错误：doc_id 无效。$_docListHint';
        final lines = <String>[];
        for (final d in docs0) {
          for (final h in d.controller.search(q, limit: 20)) {
            lines.add('《${d.title}》[节${h.sectionIndex} @${h.range.start}] …${h.preview}…');
          }
        }
        return lines.isEmpty ? '无命中' : lines.join('\n');

      case 'add_annotation':
        final d = _doc(args['doc_id'] as String?);
        if (d == null) return '错误：doc_id 无效。$_docListHint';
        final idx = (args['section_index'] as num?)?.toInt() ?? -1;
        final note = args['note'] as String? ?? '';
        final s = d.controller.sectionAt(idx);
        if (s == null || note.isEmpty) return '错误：参数无效';
        final range = CharRange(s.charOffset, s.charOffset + s.charCount);
        await (db.into(db.annotations).insert(AnnotationsCompanion.insert(
              id: '${DateTime.now().microsecondsSinceEpoch}_${d.id}_$idx',
              docId: d.id,
              rangeStart: range.start,
              rangeEnd: range.end,
              kind: AnnotationKind.note.index,
              originalText: s.plainText.length > 200
                  ? s.plainText.substring(0, 200)
                  : s.plainText,
              content: note,
              createdAt: DateTime.now(),
            )));
        return '已为《${d.title}》第 $idx 节添加批注。';

      case 'propose_rewrite':
        final d = _doc(args['doc_id'] as String?);
        if (d == null) return '错误：doc_id 无效。$_docListHint';
        final findText = args['find_text'] as String? ?? '';
        final newText = args['new_text'] as String? ?? '';
        final desc = args['description'] as String? ?? '改写提案';
        final hits = d.controller.search(findText, limit: 1);
        if (hits.isEmpty) {
          return '错误：找不到原文片段，请确保 find_text 与《${d.title}》原文完全一致（可先 search_text 精确复制）';
        }
        final edit = DocTextEdit.replace(hits.first.range, newText);
        onProposal?.call(d.id, RewriteProposal(description: desc, edit: edit));
        return '提案已生成并展示给用户，等待确认。';

      default:
        return '错误：未知工具 ${call.name}';
    }
  }
}
