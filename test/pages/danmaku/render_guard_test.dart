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

  test('small special danmaku remains renderable', () {
    expect(
      DanmakuRenderGuard.canRasterizeSpecial(_content('hello'), 2, 2, 4),
      isTrue,
    );
  });

  test('oversized special danmaku is rejected before image allocation', () {
    expect(
      DanmakuRenderGuard.canRasterizeSpecial(
        _content('弹幕' * 100, fontSize: 100),
        2,
        2,
        4,
      ),
      isFalse,
    );
  });

  test('invalid pixel ratio is rejected', () {
    expect(
      DanmakuRenderGuard.canRasterizeSpecial(_content('hello'), 0, 2, 4),
      isFalse,
    );
  });
}
