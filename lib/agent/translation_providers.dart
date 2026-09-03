import 'dart:convert';

import 'package:http/http.dart' as http;

import 'llm_client.dart';

/// 翻译提供方抽象：LLM / MyMemory（免费无 Key）/ Google gtx（免费，国内可能不通）。
abstract class TranslationProvider {
  String get id;
  String get label;
  Future<String> translate(String text, {required String targetLang});
}

/// 有限并发地映射（保持结果顺序）。慢提供方（LLM）的提速核心：
/// 一次请求翻译整页要等完整往返，切成段落并发 4 路后总耗时≈最慢一段。
Future<List<R>> mapLimited<T, R>(
    List<T> items, int limit, Future<R> Function(T) fn) async {
  final results = List<R?>.filled(items.length, null);
  var next = 0;
  Future<void> worker() async {
    while (next < items.length) {
      final i = next++;
      results[i] = await fn(items[i]);
    }
  }

  await Future.wait([
    for (var i = 0; i < limit && i < items.length; i++) worker()
  ]);
  return [for (final r in results) r!];
}

/// LLM 翻译（质量最高，用已配置的模型；按用量计费但极便宜）。
/// 长文本按段落切块并发翻译（默认 4 路），比单次大请求快数倍。
class LlmTranslationProvider implements TranslationProvider {
  LlmTranslationProvider(this.client, {this.concurrency = 4});
  final LlmClient client;
  final int concurrency;

  @override
  String get id => 'llm';
  @override
  String get label => 'LLM（已配置的模型）';

  @override
  Future<String> translate(String text, {required String targetLang}) async {
    final chunks = splitTranslationChunks(text, maxChunkChars: 1800);
    if (chunks.length <= 1) {
      return _translateOnce(chunks.isEmpty ? '' : chunks.first, targetLang);
    }
    final parts = await mapLimited(chunks, concurrency,
        (c) => _translateOnce(c, targetLang));
    return parts.join('\n\n');
  }

  Future<String> _translateOnce(String text, String targetLang) async {
    final resp = await client.chat(messages: [
      LlmMessage.system(
          '你是专业译者。将用户提供的文本翻译成${_langName(targetLang)}，'
          '保持原意、语气与段落结构，只输出译文，不要任何解释。'),
      LlmMessage.user(text),
    ], temperature: 0.3);
    return resp.content ?? '';
  }

  /// 按段落切块：尽量按空行分段，单段过长再按行切；保证顺序。
  static List<String> splitTranslationChunks(String text,
      {int maxChunkChars = 1800}) {
    if (text.length <= maxChunkChars) return [text];
    final paras = text.split('\n\n');
    final chunks = <String>[];
    final buf = StringBuffer();
    for (final para in paras) {
      if (buf.isNotEmpty && buf.length + para.length > maxChunkChars) {
        chunks.add(buf.toString());
        buf.clear();
      }
      if (buf.isNotEmpty) buf.write('\n\n');
      buf.write(para);
    }
    if (buf.isNotEmpty) chunks.add(buf.toString());
    return chunks;
  }

  static String _langName(String code) => switch (code) {
        'zh' => '中文',
        'en' => '英文',
        'ja' => '日文',
        'ko' => '韩文',
        'fr' => '法文',
        'de' => '德文',
        'es' => '西班牙文',
        'ru' => '俄文',
        _ => code,
      };
}

/// MyMemory：免费无需注册（匿名约 5000 词/天），单次 ≤500 字节，自动分块。
class MyMemoryProvider implements TranslationProvider {
  MyMemoryProvider({http.Client? httpClient, String? baseUrl})
      : _http = httpClient ?? http.Client(),
        _baseUrl = baseUrl ?? 'https://api.mymemory.translated.net';
  final http.Client _http;
  final String _baseUrl;

  @override
  String get id => 'mymemory';
  @override
  String get label => 'MyMemory（免费，无需注册）';

  @override
  Future<String> translate(String text, {required String targetLang}) async {
    // MyMemory 要求显式源语言；中文书 ↔ 英文互译的常见场景做启发式
    final source = targetLang == 'zh' ? 'en' : 'zh-CN';
    final target = targetLang == 'zh' ? 'zh-CN' : 'en-GB';
    final chunks = _chunk(text, 450);
    final out = <String>[];
    for (final chunk in chunks) {
      final uri = Uri.parse(
          '$_baseUrl/get?q=${Uri.encodeQueryComponent(chunk)}&langpair=$source|$target');
      final resp = await _http
          .get(uri)
          .timeout(const Duration(seconds: 30));
      if (resp.statusCode != 200) {
        throw Exception('MyMemory HTTP ${resp.statusCode}');
      }
      final data = jsonDecode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>;
      final status = data['responseStatus'];
      final translated =
          ((data['responseData'] ?? {}) as Map)['translatedText'] as String?;
      if (status != 200 || translated == null || translated.isEmpty) {
        throw Exception('MyMemory 错误: ${data['responseDetails']}');
      }
      out.add(translated);
    }
    return out.join('\n');
  }

  static List<String> _chunk(String text, int maxChars) {
    if (text.length <= maxChars) return [text];
    final chunks = <String>[];
    for (var i = 0; i < text.length; i += maxChars) {
      chunks.add(text.substring(i, (i + maxChars).clamp(0, text.length)));
    }
    return chunks;
  }
}

/// Google gtx 免费接口（无 Key；国内网络可能无法直连）。
class GoogleGtxProvider implements TranslationProvider {
  GoogleGtxProvider({http.Client? httpClient, String? baseUrl})
      : _http = httpClient ?? http.Client(),
        _baseUrl = baseUrl ?? 'https://translate.googleapis.com';
  final http.Client _http;
  final String _baseUrl;

  @override
  String get id => 'google';
  @override
  String get label => 'Google 免费接口（国内可能不通）';

  @override
  Future<String> translate(String text, {required String targetLang}) async {
    final target = targetLang == 'zh' ? 'zh-CN' : targetLang;
    final uri = Uri.parse(
        '$_baseUrl/translate_a/single?client=gtx&sl=auto&tl=$target&dt=t&q=${Uri.encodeQueryComponent(text)}');
    final resp = await _http
        .get(uri)
        .timeout(const Duration(seconds: 30));
    if (resp.statusCode != 200) {
      throw Exception('Google HTTP ${resp.statusCode}');
    }
    final data = jsonDecode(utf8.decode(resp.bodyBytes)) as List;
    final segs = (data[0] as List)
        .map((s) => (s as List)[0] as String)
        .join();
    return segs;
  }
}

/// 按 id 构建提供方。
TranslationProvider buildTranslationProvider(
    String id, {LlmClient? llmClient}) {
  switch (id) {
    case 'mymemory':
      return MyMemoryProvider();
    case 'google':
      return GoogleGtxProvider();
    case 'llm':
    default:
      if (llmClient == null) {
        throw ArgumentError('LLM 翻译提供方需要已配置的 LlmClient');
      }
      return LlmTranslationProvider(llmClient);
  }
}
