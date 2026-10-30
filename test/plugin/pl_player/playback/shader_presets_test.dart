import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pili_aurora/common/assets.dart';

void main() {
  test('效率档在原始尺寸阶段仅执行一套恢复网络', () {
    final restore = Assets.mpvAnime4KShadersLite.where(
      (name) => name.startsWith('Anime4K_Restore_'),
    );
    expect(restore, ['Anime4K_Restore_CNN_M.glsl']);
    final unconditionalPasses = restore.fold<int>(0, (count, name) {
      final shader = File('assets/shaders/$name').readAsStringSync();
      return count +
          RegExp(r'^//!HOOK ', multiLine: true).allMatches(shader).length;
    });
    expect(unconditionalPasses, 8);
    for (final name in Assets.mpvAnime4KShadersLite) {
      expect(File('assets/shaders/$name').existsSync(), isTrue);
    }
  });
}
