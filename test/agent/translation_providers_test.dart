import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:agent_book_reader/agent/llm_client.dart';
import 'package:agent_book_reader/agent/translation_providers.dart';

void main() {
  late HttpServer server;
  late String baseUrl;
  final requests = <Uri>[];
  final bodies = <String>[];

  setUp(() async {
    requests.clear();
    bodies.clear();
    server = await HttpServer.bind('127.0.0.1', 0);
    baseUrl = 'http://127.0.0.1:${server.port}';
    server.listen((req) async {
      requests.add(req.uri);
      final bodyText = await utf8.decoder.bind(req).join();
      bodies.add(bodyText);

      if (req.uri.path.contains('/get')) {
        // MyMemory mock：原样回显译文标记
        final q = req.uri.queryParameters['q'] ?? '';
        req.response.write(jsonEncode({
          'responseData': {'translatedText': '译[$q]'},
          'responseStatus': 200,
        }));
      } else if (req.uri.path.contains('translate_a')) {
        // Google gtx mock
        req.response.write(jsonEncode([
          [
            ['你好', 'hello', null, null, 10],
            ['世界', 'world', null, null, 10]
          ]
        ]));
      } else if (req.uri.path.contains('/chat/completions')) {
        String userText = '';
        try {
          final body = jsonDecode(bodyText) as Map<String, dynamic>;
          userText =
              ((body['messages'] as List).last as Map)['content'] as String;
        } catch (_) {}
        req.response.write(jsonEncode({
          'choices': [
            {
              'message': {'role': 'assistant', 'content': 'LLM译文[$userText]'}
            }
          ]
        }));
      }
      await req.response.close();
    });
  });

  tearDown(() async => await server.close(force: true));

  test('MyMemory：langpair 拼装 + 450 字分块 + 结果拼接', () async {
    final p = MyMemoryProvider(httpClient: null, baseUrl: baseUrl);
    final out = await p
        .translate('a' * 900 + 'END', targetLang: 'zh');
    // 901 字符 → 3 块（450+450+1），每块回显 译[<块内容>]
    expect(requests.length, 3);
    expect(out.split('\n').length, 3);
    expect(out, contains('译[END]'));
    expect(requests.first.queryParameters['langpair'], 'en|zh-CN');
  });

  test('Google gtx：解析嵌套数组并拼接', () async {
    final p = GoogleGtxProvider(baseUrl: baseUrl);
    final out = await p.translate('hello world', targetLang: 'zh');
    expect(out, '你好世界');
    expect(requests.single.queryParameters['tl'], 'zh-CN');
    expect(requests.single.queryParameters['sl'], 'auto');
  });

  test('LLM 翻译提供方：走 OpenAI 兼容 mock', () async {
    final client = LlmClient(baseUrl: baseUrl, apiKey: 'k', model: 'mock');
    final p = LlmTranslationProvider(client);
    final out = await p.translate('hello', targetLang: 'zh');
    expect(out, contains('LLM译文'));
    expect(requests.last.path, contains('/chat/completions'));
  });

  test('提供方工厂：按 id 构建', () {
    expect(buildTranslationProvider('mymemory'), isA<MyMemoryProvider>());
    expect(buildTranslationProvider('google'), isA<GoogleGtxProvider>());
    expect(() => buildTranslationProvider('llm'), throwsA(isA<ArgumentError>()));
    expect(
        buildTranslationProvider('llm',
            llmClient: LlmClient(
                baseUrl: baseUrl, apiKey: '', model: 'm')),
        isA<LlmTranslationProvider>());
  });
}
