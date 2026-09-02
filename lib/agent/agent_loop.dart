import 'dart:convert';

import 'llm_client.dart';
import 'tools.dart';

/// Agent 工具调用循环：模型回复 → 执行工具 → 回填结果 → 重复，
/// 直到无工具调用或达到 maxTurns。事件通过 onEvent 回调供 UI 渲染。
class AgentLoop {
  AgentLoop({
    required this.client,
    required this.registry,
    this.maxTurns = 8,
    this.onEvent,
  });

  final LlmClient client;
  final AgentToolHandler registry;
  final int maxTurns;
  final void Function(AgentEvent)? onEvent;

  /// 运行一轮对话（messages 为历史，末尾应是新的 user 消息）。
  /// 返回助手最终文本回复。
  Future<String> run(List<LlmMessage> messages) async {
    final working = List<LlmMessage>.of(messages);
    var lastText = '';

    for (var turn = 0; turn < maxTurns; turn++) {
      final resp = await client.chat(messages: working, tools: registry.specs);

      if (resp.toolCalls.isEmpty) {
        lastText = resp.content ?? '';
        return lastText;
      }

      working.add(LlmMessage.assistant(
        resp.content ?? '',
        toolCallsJson: jsonEncode(resp.toolCalls.map((c) => c.name).toList()),
      ));

      for (final call in resp.toolCalls) {
        onEvent?.call(AgentToolCallEvent(call.name, call.argumentsJson));
        String result;
        try {
          result = await registry.handle(call);
        } catch (e) {
          result = '工具执行异常: $e';
        }
        onEvent?.call(AgentToolResultEvent(call.name, result));
        working.add(LlmMessage.toolResult(call.id, call.name, result));
      }
    }
    return lastText.isEmpty
        ? '已达到最大工具调用轮数（$maxTurns），请缩小问题范围后重试。'
        : lastText;
  }
}
