import 'dart:convert';

import 'package:enough_convert/enough_convert.dart';

/// 文本编码探测与解码：
/// BOM（UTF-8/UTF-16LE/BE）→ UTF-8 → 失败回退 GBK（中文书常见）→ UTF-16 无 BOM 启发式。
class TextDecoder {
  TextDecoder._();

  static final GbkCodec _gbk = GbkCodec(allowInvalid: true);

  static String decode(List<int> bytes) {
    if (bytes.length >= 2) {
      if (bytes[0] == 0xFF && bytes[1] == 0xFE) {
        return _decodeUtf16(bytes.sublist(2), littleEndian: true);
      }
      if (bytes[0] == 0xFE && bytes[1] == 0xFF) {
        return _decodeUtf16(bytes.sublist(2), littleEndian: false);
      }
    }
    if (bytes.length >= 3 &&
        bytes[0] == 0xEF &&
        bytes[1] == 0xBB &&
        bytes[2] == 0xBF) {
      return utf8.decode(bytes.sublist(3), allowMalformed: true);
    }

    // 无 BOM：先按 UTF-8；出现替换符则回退 GBK
    final asUtf8 = utf8.decode(bytes, allowMalformed: true);
    if (!asUtf8.contains('\uFFFD')) return asUtf8;

    final asGbk = _gbk.decode(bytes);
    if (!asGbk.contains('\uFFFD')) return asGbk;

    // UTF-16 无 BOM 启发式：null 字节密度（每 2 字节 1 个）
    var nulls = 0;
    final check = bytes.length < 256 ? bytes.length : 256;
    for (var i = 1; i < check; i += 2) {
      if (bytes[i] == 0) nulls++;
    }
    if (nulls > check ~/ 4) return _decodeUtf16(bytes, littleEndian: true);

    return asGbk;
  }

  /// 手写 UTF-16 解码（dart:convert 不提供）：处理代理对，跳过 null 填充。
  static String _decodeUtf16(List<int> bytes, {required bool littleEndian}) {
    int unit(int i) => littleEndian
        ? (bytes[i] | (bytes[i + 1] << 8))
        : (bytes[i + 1] | (bytes[i] << 8));
    final buffer = StringBuffer();
    var i = 0;
    while (i + 1 < bytes.length) {
      final u = unit(i);
      if (u == 0) {
        i += 2;
        continue;
      }
      if (u >= 0xD800 && u <= 0xDBFF && i + 3 < bytes.length) {
        final next = unit(i + 2);
        if (next >= 0xDC00 && next <= 0xDFFF) {
          buffer.writeCharCode(0x10000 + ((u - 0xD800) << 10) + (next - 0xDC00));
          i += 4;
          continue;
        }
      }
      buffer.writeCharCode(u);
      i += 2;
    }
    return buffer.toString();
  }
}
