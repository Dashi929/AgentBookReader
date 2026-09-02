import '../core/controller/document_controller.dart';
import '../core/model/annotation.dart';
import '../core/model/char_range.dart';
import '../infra/database.dart';
import 'llm_client.dart';

/// Agent 事件（UI 订阅渲染）。
sealed class AgentEvent {
  const AgentEvent();
}

class AgentToolCallEvent extends AgentEvent {
  const AgentToolCallEvent(this.name, this.argsJson);
  final String name;
  final String argsJson;
}

class AgentToolResultEvent extends AgentEvent {
  const AgentToolResultEvent(this.name, this.result);
  final String name;
  final String result;
}

class AgentProposalEvent extends AgentEvent {
  const AgentProposalEvent(this.proposal);
  final RewriteProposal proposal;
}

/// 改写提案：Agent 不直接改原文，UI 展示后由用户确认。
class RewriteProposal {
  const RewriteProposal({required this.description, required this.edit});
  final String description;
  final DocTextEdit edit;
}

/// 工具执行器的公共接口：AgentLoop 对阅读器/工作台两种注册表通用。
abstract class AgentToolHandler {
  List<LlmToolSpec> get specs;
  Future<String> handle(ToolCall call);
}

/// 工具注册表：读工具直接执行；写工具产生提案事件并返回"待确认"。
class AgentToolRegistry implements AgentToolHandler {
  AgentToolRegistry({
    required this.controller,
    required this.db,
    required this.docId,
    this.onProposal,
  });

  final DocumentController controller;
  final AppDatabase db;
  final String docId;
  final void Function(RewriteProposal)? onProposal;

  @override
  final List<LlmToolSpec> specs = [
    const LlmToolSpec('get_outline', '获取文档大纲（各节标题与字数）', {
      'type': 'object',
      'properties': {},
    }),
    const LlmToolSpec('read_section', '按序号读取一节的全文文本', {
      'type': 'object',
      'properties': {
        'section_index': {'type': 'integer', 'description': '节序号，从 0 开始'},
      },
      'required': ['section_index'],
    }),
    const LlmToolSpec('search_text', '全文关键词搜索，返回命中与所在节', {
      'type': 'object',
      'properties': {
        'query': {'type': 'string'},
      },
      'required': ['query'],
    }),
    const LlmToolSpec('add_annotation', '为某一节添加批注（写入数据库）', {
      'type': 'object',
      'properties': {
        'section_index': {'type': 'integer'},
        'note': {'type': 'string', 'description': '批注内容'},
      },
      'required': ['section_index', 'note'],
    }),
    const LlmToolSpec('propose_rewrite', '对文中某段文字提出改写提案（需用户确认后生效）', {
      'type': 'object',
      'properties': {
        'find_text': {'type': 'string', 'description': '要替换的原文片段（必须与原文完全一致）'},
        'new_text': {'type': 'string', 'description': '改写后的文本'},
        'description': {'type': 'string', 'description': '提案说明'},
      },
      'required': ['find_text', 'new_text'],
    }),
  ];

  @override
  Future<String> handle(ToolCall call) async {
    final args = call.arguments;
    switch (call.name) {
      case 'get_outline':
        final lines = <String>[];
        for (final s in controller.document.sections) {
          lines.add('${s.index}: ${s.title} (${s.charCount} 字)');
        }
        return lines.isEmpty ? '文档为空' : lines.join('\n');

      case 'read_section':
        final idx = (args['section_index'] as num?)?.toInt() ?? -1;
        final s = controller.sectionAt(idx);
        if (s == null) return '错误：节 $idx 不存在（共 ${controller.sectionCount} 节）';
        var text = s.plainText;
        if (text.length > 6000) {
          text = '${text.substring(0, 6000)}\n…（截断，可继续用 search_text 定位）';
        }
        return '第 $idx 节「${s.title}」：\n$text';

      case 'search_text':
        final q = args['query'] as String? ?? '';
        final hits = controller.search(q, limit: 20);
        if (hits.isEmpty) return '无命中';
        return hits
            .map((h) => '[节${h.sectionIndex} @${h.range.start}] …${h.preview}…')
            .join('\n');

      case 'add_annotation':
        final idx = (args['section_index'] as num?)?.toInt() ?? -1;
        final note = args['note'] as String? ?? '';
        final s = controller.sectionAt(idx);
        if (s == null || note.isEmpty) return '错误：参数无效';
        final range = CharRange(s.charOffset, s.charOffset + s.charCount);
        await (db.into(db.annotations).insert(AnnotationsCompanion.insert(
              id: '${DateTime.now().microsecondsSinceEpoch}_$idx',
              docId: docId,
              rangeStart: range.start,
              rangeEnd: range.end,
              kind: AnnotationKind.note.index,
              originalText: s.plainText.length > 200
                  ? s.plainText.substring(0, 200)
                  : s.plainText,
              content: note,
              createdAt: DateTime.now(),
            )));
        return '已为第 $idx 节添加批注。';

      case 'propose_rewrite':
        final findText = args['find_text'] as String? ?? '';
        final newText = args['new_text'] as String? ?? '';
        final desc = args['description'] as String? ?? '改写提案';
        final hits = controller.search(findText, limit: 1);
        if (hits.isEmpty) {
          return '错误：找不到原文片段，请确保 find_text 与原文完全一致（可先 search_text 精确复制）';
        }
        final edit = DocTextEdit.replace(hits.first.range, newText);
        onProposal?.call(RewriteProposal(description: desc, edit: edit));
        return '提案已生成并展示给用户，等待确认。';

      default:
        return '错误：未知工具 ${call.name}';
    }
  }
}
