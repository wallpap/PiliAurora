import 'package:pili_aurora/pages/danmaku/render_guard.dart';
import 'package:canvas_danmaku/canvas_danmaku.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

SpecialDanmakuContentItem _content(String text, {double fontSize = 20}) =>
    SpecialDanmakuContentItem(
      text,
      duration: 1000,
      color: Colors.white,
      fontSize: fontSize,
      translateXTween: ConstantTween<double>(0),
      translateYTween: ConstantTween<double>(0),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('高级弹幕只在尺寸和像素比有效且未超预算时允许分配栅格', () {
    for (final (content, pixelRatio, allowed) in [
      (_content('hello'), 2.0, true),
      (_content('弹幕' * 100, fontSize: 100), 2.0, false),
      (_content('hello'), 0.0, false),
    ]) {
      expect(
        DanmakuRenderGuard.canRasterizeSpecial(content, pixelRatio, 2, 4),
        allowed,
        reason: 'textLength=${content.text.length}, pixelRatio=$pixelRatio',
      );
    }
  });
}
