import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../agent/agent_loop.dart';
import '../agent/agent_settings.dart';
import '../agent/llm_client.dart';
import '../agent/tools.dart';
import '../core/controller/plain_text_document.dart';
import '../infra/agent_repository.dart';
import '../l10n/app_localizations.dart';
import '../state/app_state.dart';

/// Agent 对话面板（阅读器内悬浮）。
class AgentPanel extends ConsumerStatefulWidget {
  const AgentPanel({
    super.key,
    required this.docId,
    required this.controller,
    required this.theme,
    required this.onClose,
  });

  final String docId;
  final PlainTextDocument controller;
  final ReaderTheme theme;
  final VoidCallback onClose;

  @override
  ConsumerState<AgentPanel> createState() => _AgentPanelState();
}

class _AgentPanelState extends ConsumerState<AgentPanel> {
  final _input = TextEditingController();
  final _scroll = ScrollController();
  final List<_ChatEntry> _entries = [];
  bool _busy = false;
  AgentRepository? _repo;
  String? _sessionId;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    final repo = AgentRepository(ref.read(appDatabaseProvider));
    final sessionId = await repo.ensureSession(widget.docId);
    final history = await repo.messages(sessionId);
    if (mounted) {
      setState(() {
        _repo = repo;
        _sessionId = sessionId;
        _entries.addAll(history
            .map((m) => _ChatEntry(role: m.role, text: m.content)));
      });
      _scrollToBottom();
    }
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.jumpTo(_scroll.position.maxScrollExtent);
      }
    });
  }

  Future<void> _send() async {
    final text = _input.text.trim();
    if (text.isEmpty || _busy) return;
    // 会话初始化是异步的：未就绪时先等它完成，避免丢消息
    if (_repo == null || _sessionId == null) {
      _addEntry('system', '会话尚未就绪，请稍候重试');
      return;
    }
    final settings = await AgentSettings.instance.read();
    if (settings.baseUrl.isEmpty || settings.model.isEmpty) {
      _addEntry('system', 'LLM 未配置：请在书架右上角设置中填写 baseURL/model');
      return;
    }

    _input.clear();
    _addEntry('user', text);
    setState(() => _busy = true);
    final repo = _repo!;

    try {
      await repo.appendMessage(
          sessionId: _sessionId!, role: 'user', content: text);
      final history = await repo.loadLlmHistory(_sessionId!);

      final client = LlmClient(
          baseUrl: settings.baseUrl,
          apiKey: settings.apiKey,
          model: settings.model);
      final registry = AgentToolRegistry(
        controller: widget.controller,
        db: ref.read(appDatabaseProvider),
        docId: widget.docId,
        onProposal: (proposal) {
          _addEntry('proposal', '改写提案：${proposal.description}');
          _showProposalDialog(proposal);
        },
      );
      final loop = AgentLoop(client: client, registry: registry, onEvent: (e) {
        if (e is AgentToolCallEvent) {
          _addEntry('tool', '🔧 ${e.name}');
          _scrollToBottom();
        }
      });

      // 阅读器内的 Agent 只能处理当前文档：工具注册表仅挂载了这一个
      // controller（结构性隔离），并在系统提示词中再次声明该限制。
      final system = '你是 AgentBookReader 的阅读助手。用户正在阅读一份文档，'
          '你只能处理当前打开的这一份文档，无法访问其他文档。'
          '你可以使用提供的工具读取大纲/内容、搜索、添加批注或提出改写提案。'
          '回答使用用户提问的语言。';
      final reply = await loop.run([LlmMessage.system(system), ...history]);

      await repo.appendMessage(
          sessionId: _sessionId!, role: 'assistant', content: reply);
      _addEntry('assistant', reply);
    } catch (e) {
      _addEntry('system', '出错了：$e');
    } finally {
      if (mounted) setState(() => _busy = false);
      _scrollToBottom();
    }
  }

  void _addEntry(String role, String text) {
    setState(() => _entries.add(_ChatEntry(role: role, text: text)));
    _scrollToBottom();
  }

  void _showProposalDialog(RewriteProposal proposal) {
    final s = AppLocalizations.of(context)!;
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(s.proposalTitle),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          Align(
              alignment: Alignment.centerLeft,
              child: Text(proposal.description,
                  style: const TextStyle(fontWeight: FontWeight.bold))),
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerLeft,
            child: Text('原文：${widget.controller.textAt(proposal.edit.range)}'),
          ),
          const SizedBox(height: 8),
          Align(
              alignment: Alignment.centerLeft,
              child: Text('改为：${proposal.edit.newText}')),
        ]),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(s.reject)),
          FilledButton(
            onPressed: () async {
              await widget.controller.applyEdit(proposal.edit);
              if (context.mounted) Navigator.pop(context);
            },
            child: Text(s.apply),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = widget.theme;
    final s = AppLocalizations.of(context)!;
    return Align(
      alignment: Alignment.bottomRight,
      child: Container(
        margin: const EdgeInsets.all(12),
        width: 420,
        height: 480,
        decoration: BoxDecoration(
          color: theme.background,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: theme.text.withValues(alpha: 0.2)),
          boxShadow: [
            BoxShadow(
                color: Colors.black.withValues(alpha: 0.3), blurRadius: 12)
          ],
        ),
        child: Column(children: [
          Container(
            height: 44,
            padding: const EdgeInsets.symmetric(horizontal: 8),
            decoration: BoxDecoration(
              color: theme.text.withValues(alpha: 0.06),
              borderRadius:
                  const BorderRadius.vertical(top: Radius.circular(12)),
            ),
            child: Row(children: [
              Icon(Icons.auto_awesome, size: 18, color: theme.text),
              const SizedBox(width: 6),
              Expanded(
                  child: Text(s.agentPanel,
                      style: TextStyle(color: theme.text, fontSize: 14))),
              IconButton(
                  icon: Icon(Icons.close, size: 18, color: theme.text),
                  onPressed: widget.onClose),
            ]),
          ),
          Expanded(
            child: ListView.builder(
              controller: _scroll,
              padding: const EdgeInsets.all(8),
              itemCount: _entries.length,
              itemBuilder: (context, i) {
                final e = _entries[i];
                final isUser = e.role == 'user';
                final isSystem = e.role == 'system' || e.role == 'tool';
                return Align(
                  alignment:
                      isUser ? Alignment.centerRight : Alignment.centerLeft,
                  child: Container(
                    margin: const EdgeInsets.symmetric(vertical: 3),
                    padding: const EdgeInsets.symmetric(
                        horizontal: 10, vertical: 6),
                    constraints: const BoxConstraints(maxWidth: 340),
                    decoration: BoxDecoration(
                      color: isSystem
                          ? theme.text.withValues(alpha: 0.08)
                          : isUser
                              ? Colors.teal.withValues(alpha: 0.85)
                              : theme.text.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(e.text,
                        style: TextStyle(color: theme.text, fontSize: 13)),
                  ),
                );
              },
            ),
          ),
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
                color: theme.text.withValues(alpha: 0.06),
                borderRadius:
                    const BorderRadius.vertical(bottom: Radius.circular(12))),
            child: Row(children: [
              Expanded(
                child: TextField(
                  controller: _input,
                  style: TextStyle(color: theme.text, fontSize: 13),
                  enabled: !_busy,
                  textInputAction: TextInputAction.send,
                  onSubmitted: (_) => _send(),
                  decoration: InputDecoration(
                    hintText: s.agentAsk,
                    hintStyle: TextStyle(
                        color: theme.text.withValues(alpha: 0.4),
                        fontSize: 13),
                    border: InputBorder.none,
                    isDense: true,
                  ),
                ),
              ),
              IconButton(
                icon: _busy
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2))
                    : Icon(Icons.send, size: 20, color: theme.text),
                onPressed: _busy ? null : _send,
              ),
            ]),
          ),
        ]),
      ),
    );
  }
}

class _ChatEntry {
  _ChatEntry({required this.role, required this.text});
  final String role; // user | assistant | tool | system | proposal
  final String text;
}
