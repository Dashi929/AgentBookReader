import 'dart:convert';

import 'package:http/http.dart' as http;

/// OpenAI 兼容 Chat Completions 客户端（DeepSeek/Qwen/GLM/OpenAI 等通用）。
/// MVP 只实现非流式（工具循环需要完整 tool_calls；对话面板轮询展示即可）。
class LlmClient {
  LlmClient({
    required String baseUrl,
    required this.apiKey,
    required this.model,
    http.Client? httpClient,
    this.requestTimeout = LlmClient.defaultRequestTimeout,
  })  : baseUrl = baseUrl,
        _http = httpClient ?? http.Client(),
        _endpoint = _normalizeEndpoint(baseUrl);

  final String baseUrl;
  final String apiKey;
  final String model;
  final http.Client _http;
  final String _endpoint;

  /// 请求超时（默认 300s：推理类模型首响应慢，且整节/整篇翻译等
  /// 长生成任务单次可能输出数千字，120s 不够）。
  static const defaultRequestTimeout = Duration(seconds: 300);
  final Duration requestTimeout;

  /// Base URL 防呆归一化：
  /// - 去尾部斜杠
  /// - 已含 /chat/completions 则直接用
  /// - 缺 /v1 且不是明显完整路径时自动补 /v1
  static String _normalizeEndpoint(String baseUrl) {
    var url = baseUrl.trim();
    if (url.isEmpty) url = 'https://api.deepseek.com/v1';
    if (url.endsWith('/')) url = url.substring(0, url.length - 1);
    if (url.endsWith('/chat/completions')) return url;
    // 常见根地址自动补 /v1（如 https://api.deepseek.com）
    if (!RegExp(r'/v\d+$').hasMatch(url) && !url.endsWith('/v1')) {
      url = '$url/v1';
    }
    return '$url/chat/completions';
  }

  Future<LlmResponse> chat({
    required List<LlmMessage> messages,
    List<LlmToolSpec>? tools,
    double temperature = 0.7,
  }) async {
    final body = {
      'model': model,
      'messages': messages.map((m) => m.toJson()).toList(),
      'temperature': temperature,
      if (tools != null && tools.isNotEmpty)
        'tools': tools
            .map((t) => {
                  'type': 'function',
                  'function': {
                    'name': t.name,
                    'description': t.description,
                    'parameters': t.parameters,
                  },
                })
            .toList(),
    };

    final resp = await _http
        .post(
          Uri.parse(_endpoint),
          headers: {
            'Content-Type': 'application/json',
            if (apiKey.isNotEmpty) 'Authorization': 'Bearer $apiKey',
          },
          body: jsonEncode(body),
        )
        .timeout(requestTimeout);

    if (resp.statusCode != 200) {
      throw LlmException('HTTP ${resp.statusCode}: ${resp.body}');
    }

    final data = jsonDecode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>;
    final choices = data['choices'] as List?;
    if (choices == null || choices.isEmpty) {
      throw LlmException('响应缺少 choices');
    }
    final message = (choices.first as Map)['message'] as Map<String, dynamic>;
    final rawCalls = message['tool_calls'] as List?;
    return LlmResponse(
      content: message['content'] as String?,
      toolCalls: (rawCalls ?? [])
          .map((c) => ToolCall(
                id: (c as Map)['id'] as String? ?? '',
                name: ((c['function'] ?? {}) as Map)['name'] as String? ?? '',
                argumentsJson:
                    ((c['function'] ?? {}) as Map)['arguments'] as String? ?? '{}',
              ))
          .toList(),
    );
  }
}

class LlmMessage {
  LlmMessage({required this.role, required this.content})
      : toolCallId = null,
        toolCallsJson = null;
  LlmMessage.system(this.content)
      : role = 'system',
        toolCallId = null,
        toolCallsJson = null;
  LlmMessage.user(this.content)
      : role = 'user',
        toolCallId = null,
        toolCallsJson = null;
  LlmMessage.assistant(this.content, {this.toolCallsJson})
      : role = 'assistant',
        toolCallId = null;
  LlmMessage.toolResult(this.toolCallId, String name, this.content)
      : role = 'tool',
        toolCallsJson = name;

  final String role;
  final String content;
  final String? toolCallId;
  final String? toolCallsJson; // 借存工具名

  Map<String, dynamic> toJson() => {
        'role': role,
        'content': content,
        if (role == 'tool') 'tool_call_id': toolCallId,
        if (role == 'tool') 'name': toolCallsJson,
      };
}

class LlmToolSpec {
  const LlmToolSpec(this.name, this.description, this.parameters);
  final String name;
  final String description;
  final Map<String, dynamic> parameters;
}

class ToolCall {
  const ToolCall({required this.id, required this.name, required this.argumentsJson});
  final String id;
  final String name;
  final String argumentsJson;

  Map<String, dynamic> get arguments {
    try {
      return jsonDecode(argumentsJson) as Map<String, dynamic>;
    } catch (_) {
      return {};
    }
  }
}

class LlmResponse {
  const LlmResponse({required this.content, required this.toolCalls});
  final String? content;
  final List<ToolCall> toolCalls;
}

class LlmException implements Exception {
  const LlmException(this.message);
  final String message;
  @override
  String toString() => message;
}
