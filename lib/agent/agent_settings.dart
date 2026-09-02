import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// LLM 连接配置（secure storage 存 Key）。
class AgentSettings {
  AgentSettings._(this._storage);
  final FlutterSecureStorage _storage;

  static AgentSettings? _instance;
  static AgentSettings get instance => _instance!;

  static Future<void> init() async {
    _instance ??= AgentSettings._(const FlutterSecureStorage());
  }

  static const _kBaseUrl = 'llm.baseUrl';
  static const _kApiKey = 'llm.apiKey';
  static const _kModel = 'llm.model';

  Future<({String baseUrl, String apiKey, String model})> read() async {
    final baseUrl = await _storage.read(key: _kBaseUrl) ?? '';
    final apiKey = await _storage.read(key: _kApiKey) ?? '';
    final model = await _storage.read(key: _kModel) ?? '';
    return (baseUrl: baseUrl, apiKey: apiKey, model: model);
  }

  Future<void> save(
      {required String baseUrl, required String apiKey, required String model}) async {
    await _storage.write(key: _kBaseUrl, value: baseUrl);
    await _storage.write(key: _kApiKey, value: apiKey);
    await _storage.write(key: _kModel, value: model);
  }

  bool get configuredReady => true; // 校验在 UI 层做
}
