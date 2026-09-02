import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:agent_book_reader/agent/llm_client.dart';

/// 启动一个本地 mock OpenAI 兼容服务器，验证 LlmClient 请求/解析。
void main() {
  late HttpServer server;
  late String baseUrl;
  final requests = <Map<String, dynamic>>[];

  setUp(() async {
    requests.clear();
    server = await HttpServer.bind('127.0.0.1', 0);
    baseUrl = 'http://127.0.0.1:${server.port}/v1';
    server.listen((req) async {
      try {
        final bodyText = await utf8.decoder.bind(req).join();
        final body =
            bodyText.isEmpty ? <String, dynamic>{} : jsonDecode(bodyText) as Map<String, dynamic>;
        requests.add(body);
        final model = body['model'];
        final last = (body['messages'] as List).last as Map<String, dynamic>;

        if (model == 'boom') {
          req.response.statusCode = 500;
          req.response.write(jsonEncode({'error': 'mock failure'}));
          await req.response.close();
          return;
        }

        Map<String, dynamic> message;
        if (last['role'] == 'tool') {
          message = {'role': 'assistant', 'content': '根据工具结果回答'};
        } else if (body.containsKey('tools')) {
          message = {
            'role': 'assistant',
            'content': null,
            'tool_calls': [
              {
                'id': 'call_1',
                'type': 'function',
                'function': {
                  'name': 'get_outline',
                  'arguments': '{}',
                },
              },
            ],
          };
        } else {
          message = {
            'role': 'assistant',
            'content': '你好，我是 mock 模型 ($model)'
          };
        }

        final resp = jsonEncode({
          'choices': [
            {'message': message}
          ],
        });
        req.response.headers.contentType = ContentType.json;
        req.response.write(resp);
        await req.response.close();
      } catch (e) {
        req.response.statusCode = 500;
        req.response.write(jsonEncode({'mockError': '$e'}));
        await req.response.close();
      }
    });
  });

  tearDown(() async => await server.close(force: true));

  test('普通对话：请求头/模型/消息正确，解析 content', () async {
    final client = LlmClient(
        baseUrl: baseUrl, apiKey: 'sk-test', model: 'mock-model');
    final resp = await client
        .chat(messages: [LlmMessage.user('你好')]);

    expect(resp.content, contains('mock 模型'));
    expect(resp.toolCalls, isEmpty);
    expect(requests.single['model'], 'mock-model');
    expect(
        (requests.single['messages'] as List).first['content'], '你好');
  });

  test('带工具请求：解析 tool_calls', () async {
    final client = LlmClient(
        baseUrl: baseUrl, apiKey: '', model: 'mock-model');
    final resp = await client.chat(
      messages: [LlmMessage.user('列一下大纲')],
      tools: [
        const LlmToolSpec('get_outline', '大纲', {'type': 'object', 'properties': {}}),
      ],
    );

    expect(resp.toolCalls.length, 1);
    expect(resp.toolCalls.first.name, 'get_outline');
    expect(requests.single['tools'], isNotNull);
  });

  test('HTTP 非 200 → LlmException', () async {
    final client = LlmClient(
        baseUrl: baseUrl, apiKey: '', model: 'boom');
    await expectLater(client.chat(messages: [LlmMessage.user('x')]),
        throwsA(isA<LlmException>()));
  });
}
