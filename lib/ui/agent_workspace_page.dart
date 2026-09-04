import 'dart:convert';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../agent/agent_loop.dart';
import '../agent/agent_settings.dart';
import '../agent/llm_client.dart';
import '../agent/tools.dart';
import '../agent/translation_providers.dart';
import '../agent/translation_task.dart';
import '../agent/workspace_tools.dart';
import '../core/controller/plain_text_document.dart';
import '../core/io/text_decoder.dart';
import '../core/model/char_range.dart';
import '../core/parser/docx_extractor.dart';
import '../core/parser/epub_extractor.dart';
import '../infra/agent_repository.dart';
import '../l10n/app_localizations.dart';
import '../state/app_state.dart';

/// Agent 工作台：从书架勾选一个或多个文档交给 Agent 处理。
/// 与阅读器内的悬浮助手（只能处理当前文档）不同，这里可跨文档读取/搜索/批注/改写。
class AgentWorkspacePage extends ConsumerStatefulWidget {
  const AgentWorkspacePage({super.key});

  @override
  ConsumerState<AgentWorkspacePage> createState() => _AgentWorkspacePageState();
}

class _AgentWorkspacePageState extends ConsumerState<AgentWorkspacePage> {
  final _input = TextEditingController();
  final _scroll = ScrollController();
  final List<_ChatEntry> _entries = [];
  final Set<String> _selected = {};
  final Map<String, WorkspaceDoc> _docs = {};
  bool _busy = false;
  bool _loading = false;
  AgentRepository? _repo;
  String? _sessionId;

  @override
  void initState() {
    super.initState();
    _repo = AgentRepository(ref.read(appDatabaseProvider));
    _initSession();
  }

  Future<void> _initSession() async {
    // 工作台会话不绑定单一文档（docId = null）
    final sessionId = await _repo!.ensureSession(null);
    final history = await _repo!.messages(sessionId);
    if (mounted) {
      setState(() {
        _sessionId = sessionId;
        _entries.addAll(history.map((m) => _ChatEntry(role: m.role, text: m.content)));
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

  Future<void> _toggleSelect(BookEntry b) async {
    setState(() {
      if (!_selected.remove(b.id)) _selected.add(b.id);
    });
    if (_selected.contains(b.id) && !_docs.containsKey(b.id)) {
      setState(() => _loading = true);
      try {
        final doc = await _loadDoc(b);
        if (doc != null && mounted) {
          setState(() => _docs[b.id] = doc);
        }
      } finally {
        if (mounted) setState(() => _loading = false);
      }
    } else if (!_selected.contains(b.id)) {
      setState(() => _docs.remove(b.id));
    }
  }

  Future<WorkspaceDoc?> _loadDoc(BookEntry b) async {
    try {
      // pdf 不走文本管道（渲染层独立），工作台暂不加载
      if (b.extension == 'pdf') return null;
      final bytes = await XFile(b.path).readAsBytes();
      final ext = b.extension;
      final (format, content) = ext == 'docx'
          ? ('md', DocxExtractor.extractAsMarkdown(bytes))
          : ext == 'epub'
              ? ('md', EpubExtractor.extractAsMarkdown(bytes))
              : (ext, TextDecoder.decode(bytes));
      final df = switch (format) {
        'md' => DocFormat.md,
        'json' => DocFormat.json,
        _ => DocFormat.txt,
      };
      final doc = await PlainTextDocument.create(b.id, b.title, df, content);
      return WorkspaceDoc(
        id: b.id,
        title: b.title,
        controller: doc,
        format: format,
        path: b.path,
      );
    } catch (_) {
      return null;
    }
  }

  /// 提案确认后：内存 applyEdit；txt/md/json 且有原文件时写回（先备份 .bak）。
  Future<void> _applyProposal(String docId, RewriteProposal proposal) async {
    final doc = _docs[docId];
    if (doc == null) return;
    await doc.controller.applyEdit(proposal.edit);
    final b = ref.read(libraryProvider.notifier).byId(docId);
    if (b != null && {'txt', 'md', 'json'}.contains(b.extension)) {
      try {
        final bytes = await XFile(b.path).readAsBytes();
        await XFile.fromData(bytes).saveTo('${b.path}.bak');
        final out = b.extension == 'json'
            ? jsonEncode(doc.controller.document.sections
                .map((sec) => {
                      'index': sec.index,
                      'title': sec.title,
                      'text': sec.plainText,
                    })
                .toList())
            : doc.controller.rawText;
        await XFile.fromData(utf8.encode(out)).saveTo(b.path);
        if (mounted) {
          ScaffoldMessenger.of(context)
              .showSnackBar(const SnackBar(content: Text('原文件已备份(.bak)并更新')));
        }
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('写回原文件失败：$e')));
        }
      }
    }
  }

  void _showProposalDialog(String docId, RewriteProposal proposal) {
    final s = AppLocalizations.of(context)!;
    final doc = _docs[docId];
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('${s.proposalTitle} · ${doc?.title ?? docId}'),
        content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(proposal.description, style: const TextStyle(fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          Text('原文：${doc?.controller.textAt(proposal.edit.range) ?? '(文档未加载)'}'),
          const SizedBox(height: 8),
          Text('改为：${proposal.edit.newText}'),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: Text(s.reject)),
          FilledButton(
            onPressed: () async {
              await _applyProposal(docId, proposal);
              if (context.mounted) Navigator.pop(context);
            },
            child: Text(s.apply),
          ),
        ],
      ),
    );
  }

  Future<void> _send() async {
    final text = _input.text.trim();
    if (text.isEmpty || _busy) return;
    final settings = await AgentSettings.instance.read();
    if (settings.baseUrl.isEmpty || settings.model.isEmpty) {
      _addEntry('system', 'LLM 未配置：请在书架右上角设置中填写 baseURL/model');
      return;
    }
    // 不强制预选文档：未选时由 Agent 引导用户去勾选
    _input.clear();
    _addEntry('user', text);
    setState(() => _busy = true);
    final repo = _repo!;

    try {
      await repo.appendMessage(sessionId: _sessionId!, role: 'user', content: text);
      final history = await repo.loadLlmHistory(_sessionId!);

      final client = LlmClient(baseUrl: settings.baseUrl, apiKey: settings.apiKey, model: settings.model);
      final registry = WorkspaceToolRegistry(
        docs: _docs,
        db: ref.read(appDatabaseProvider),
        onProposal: (docId, proposal) {
          _addEntry('proposal', '改写提案：《${_docs[docId]?.title ?? docId}》 ${proposal.description}');
          _showProposalDialog(docId, proposal);
        },
      );
      final loop = AgentLoop(
          client: client,
          registry: registry,
          maxTurns: 16, // 分节处理长任务时需要更多轮次
          onEvent: (e) {
        if (e is AgentToolCallEvent) {
          _addEntry('tool', '🔧 ${e.name}');
          _scrollToBottom();
        }
      });

      final system = '你是 AgentBookReader 的文档工作台助手，可以跨文档处理：读取大纲/内容、'
          '搜索、添加批注、提出改写提案。只有用户通过"选择文档"按钮勾选并加载的文档才能被工具操作。'
          '如果当前没有已加载的文档、或缺少用户想处理的文档，'
          '不要编造内容，请提示用户点击"选择文档"按钮勾选对应文档后再发一次请求。'
          '涉及具体文档时先用 list_documents 确认文档 id，再传对应的 doc_id。'
          '长任务（如整篇翻译/摘要）必须按节分批处理：每轮只用 read_section 读一节，'
          '并在回复中给出该节的结果，等用户说"继续"再做下一节，绝不要试图一次性输出整篇结果。'
          '回答使用用户提问的语言。';
      final reply = await loop.run([LlmMessage.system(system), ...history]);

      await repo.appendMessage(sessionId: _sessionId!, role: 'assistant', content: reply);
      _addEntry('assistant', reply);
    } catch (e) {
      final msg = e.toString().contains('TimeoutException')
          ? 'LLM 请求超时（最长等待 5 分钟）。任务可能太大：请让 Agent 按节分批处理'
              '（如"先翻译第 0 节"），或稍后重试。'
          : '出错了：$e';
      _addEntry('system', msg);
    } finally {
      if (mounted) setState(() => _busy = false);
      _scrollToBottom();
    }
  }

  /// 按需弹出的文档勾选对话框：Agent 提示需要文档、或用户主动点按钮时打开。
  Future<void> _showDocPicker() async {
    final s = AppLocalizations.of(context)!;
    final books = ref.read(libraryProvider);
    await showDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialog) => AlertDialog(
          title: Text(s.agentWorkspaceSelect),
          content: SizedBox(
            width: 420,
            height: 320,
            child: books.isEmpty
                ? Center(child: Text(s.importFiles, style: const TextStyle(color: Colors.grey)))
                : ListView.builder(
                    itemCount: books.length,
                    itemBuilder: (context, i) {
                      final b = books[i];
                      final checked = _selected.contains(b.id);
                      final loaded = _docs.containsKey(b.id);
                      return CheckboxListTile(
                        dense: true,
                        value: checked,
                        controlAffinity: ListTileControlAffinity.leading,
                        title: Text(b.title,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 14)),
                        subtitle: loaded
                            ? Text(
                                '${_docs[b.id]!.controller.sectionCount} 节 · ${_docs[b.id]!.controller.charCount} 字',
                                style:
                                    const TextStyle(fontSize: 11, color: Colors.teal))
                            : null,
                        onChanged: (_) async {
                          await _toggleSelect(b);
                          setDialog(() {});
                        },
                      );
                    },
                  ),
          ),
          actions: [
            if (_loading)
              const Padding(
                padding: EdgeInsets.only(right: 16),
                child: SizedBox(
                    width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
              ),
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(s.confirm),
            ),
          ],
        ),
      ),
    );
    if (mounted) setState(() {});
  }

  /// 一键任务：整篇翻译已加载文档并导出为 Markdown 文件。
  Future<void> _startWholeDocTranslation() async {
    final s = AppLocalizations.of(context)!;
    if (_docs.isEmpty) {
      _addEntry('system', '请先点击右上角"选择文档"勾选要翻译的文档');
      return;
    }
    // 选目标语言
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

    // 构建翻译提供方（与设置页选择的翻译服务一致）
    final providerId = PrefsService.instance.loadTranslationProvider();
    final settings = await AgentSettings.instance.read();
    final LlmClient? llm = providerId == 'llm'
        ? LlmClient(baseUrl: settings.baseUrl, apiKey: settings.apiKey, model: settings.model)
        : null;
    if (providerId == 'llm' && settings.baseUrl.isEmpty) {
      _addEntry('system', '翻译服务当前选择 LLM，但 LLM 未配置：请到书架设置页填写，'
          '或把翻译服务切换为 MyMemory（免费无需注册）');
      return;
    }
    final provider = buildTranslationProvider(providerId, llmClient: llm);
    if (!mounted) return;

    // 进度对话框（不可点外部关闭，可取消）
    var cancelled = false;
    var done = 0;
    var currentDoc = '';
    void Function()? closeDialog;
    void Function()? setDialogState;
    final total = _docs.values
        .fold(0, (n, d) => n + d.controller.document.sections.length);
    final task = WholeDocTranslationTask(
      docs: _docs.values.toList(),
      db: ref.read(appDatabaseProvider),
      provider: provider,
      targetLang: langCode,
    );
    final dialog = showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialog) {
          closeDialog = () => Navigator.pop(context);
          setDialogState = () => setDialog(() {});
          return AlertDialog(
            title: const Text('整篇翻译中…'),
            content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              LinearProgressIndicator(value: total == 0 ? 0 : done / total),
              const SizedBox(height: 12),
              Text('$done / $total 节 · $currentDoc'),
              const SizedBox(height: 4),
              const Text('已译节会缓存，中断后重跑只补缺的节',
                  style: TextStyle(fontSize: 12, color: Colors.grey)),
            ]),
            actions: [
              TextButton(
                onPressed: () {
                  cancelled = true;
                  closeDialog?.call();
                },
                child: const Text('取消'),
              ),
            ],
          );
        },
      ),
    );

    try {
      final exported = await task.run(
        onProgress: (d, t, docTitle) {
          done = d;
          currentDoc = docTitle;
          setDialogState?.call();
        },
        cancelled: () => cancelled,
      );
      if (cancelled) {
        _addEntry('system', '整篇翻译已取消（已完成的节已缓存，可重新运行续翻）');
        return;
      }
      for (final entry in exported.entries) {
        await saveTranslationFile(entry.key, entry.value);
        _addEntry('system', '✅ 整篇翻译完成（${targetLangName(langCode)}，${provider.label}）：${entry.key}');
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text('${s.translate}完成：${exported.length} 个文件')));
      }
    } catch (e) {
      _addEntry('system', '整篇翻译失败：$e（已译节已缓存，修复后重跑会续翻）');
    } finally {
      closeDialog?.call();
      await dialog;
    }
  }

  void _addEntry(String role, String text) {
    setState(() => _entries.add(_ChatEntry(role: role, text: text)));
    _scrollToBottom();
  }

  @override
  Widget build(BuildContext context) {
    final s = AppLocalizations.of(context)!;
    return Scaffold(
      appBar: AppBar(title: Text('${s.agentPanel} · ${s.library}'), actions: [
        if (_docs.isNotEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 14),
            child: Chip(
              label: Text('${_docs.length}',
                  style: const TextStyle(fontSize: 12, color: Colors.white)),
              backgroundColor: Colors.teal,
              visualDensity: VisualDensity.compact,
              padding: EdgeInsets.zero,
            ),
          ),
        IconButton(
          tooltip: '整篇翻译并导出',
          icon: const Icon(Icons.translate),
          onPressed: _docs.isEmpty ? null : _startWholeDocTranslation,
        ),
        IconButton(
          tooltip: s.agentWorkspaceSelect,
          icon: const Icon(Icons.library_books_outlined),
          onPressed: _loading ? null : _showDocPicker,
        ),
        const SizedBox(width: 8),
      ]),
      body: Column(children: [
        // 对话区
        Expanded(
          child: ListView.builder(
            controller: _scroll,
            padding: const EdgeInsets.all(8),
            itemCount: _entries.length,
            itemBuilder: (context, i) {
              final e = _entries[i];
              final isUser = e.role == 'user';
              final isSystem = e.role == 'system' || e.role == 'tool' || e.role == 'proposal';
              return Align(
                alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
                child: Container(
                  margin: const EdgeInsets.symmetric(vertical: 3),
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  constraints: const BoxConstraints(maxWidth: 560),
                  decoration: BoxDecoration(
                    color: isSystem
                        ? Colors.grey.withValues(alpha: 0.12)
                        : isUser
                            ? Colors.teal.withValues(alpha: 0.85)
                            : Colors.teal.withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(e.text, style: const TextStyle(fontSize: 13)),
                ),
              );
            },
          ),
        ),
        SafeArea(
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(border: Border(top: BorderSide(color: Colors.grey.shade300))),
            child: Row(children: [
              Expanded(
                child: TextField(
                  controller: _input,
                  enabled: !_busy,
                  textInputAction: TextInputAction.send,
                  onSubmitted: (_) => _send(),
                  decoration: InputDecoration(
                    hintText: s.agentWorkspaceAsk,
                    hintStyle: const TextStyle(fontSize: 13),
                    border: InputBorder.none,
                    isDense: true,
                  ),
                ),
              ),
              IconButton(
                icon: _busy
                    ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.send),
                onPressed: _busy ? null : _send,
              ),
            ]),
          ),
        ),
      ]),
    );
  }
}

class _ChatEntry {
  _ChatEntry({required this.role, required this.text});
  final String role; // user | assistant | tool | system | proposal
  final String text;
}
