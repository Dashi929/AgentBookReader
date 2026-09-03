import 'package:flutter_test/flutter_test.dart';
import 'package:agent_book_reader/core/model/extracted_image.dart';

void main() {
  test('ensureStandaloneImageLines：并段占位符拆为独立段', () {
    final out = ensureStandaloneImageLines('正文A[[IMG:img1]]正文B');
    expect(out, contains('\n\n[[IMG:img1]]\n\n'));
    // 拆分后每个占位符行都能被整行正则匹配
    for (final line in out.split('\n')) {
      final m = imagePlaceholderRegex.firstMatch(line.trim());
      if (line.trim().startsWith('[[IMG:')) {
        expect(m, isNotNull);
      }
    }
  });

  test('ensureStandaloneImageLines：已独立/带空格的占位符保持不变语义', () {
    final out = ensureStandaloneImageLines('[[IMG:img1]]');
    expect(out, contains('[[IMG:img1]]'));
    final out2 = ensureStandaloneImageLines('前段\n\n [[IMG:img2]] \n\n后段');
    expect(out2, contains('[[IMG:img2]]'));
  });
}
