import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:ui' as ui;

import 'package:flutter/services.dart';

import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pili_aurora/common/widgets/custom_icon.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    await (FontLoader(
      'PiliAuroraIcons',
    )..addFont(rootBundle.load('assets/fonts/piliaurora_icons.ttf'))).load();
  });

  test('32 个字体字形与 SVG 源稿轮廓一致，Dart 定义与集中映射一致', () async {
    expect(CustomIcons.dm_on.fontFamily, 'PiliAuroraIcons');
    final dart = File('lib/common/widgets/custom_icon.dart').readAsStringSync();
    final definitions = {
      for (final match in RegExp(
        r'static const (\w+) = IconData\((0x[0-9a-f]+), fontFamily: _family\)',
      ).allMatches(dart))
        match[1]!: int.parse(match[2]!.substring(2), radix: 16),
    };
    expect(definitions.length, 32);
    expect(definitions.values.toSet().length, definitions.length);
    expect(definitions.values, everyElement(inInclusiveRange(0xe000, 0xf8ff)));

    // 源稿属于本机研发资料，公开检出可能没有 doc/dev/artwork/。此时仍
    // 检查提交的字体契约：每个生成字形都必须能够实际绘制出非空像素。
    final manifestFile = File('doc/dev/artwork/icons/manifest.json');
    if (!manifestFile.existsSync()) {
      for (final codepoint in definitions.values) {
        final recorder = ui.PictureRecorder();
        final painter =
            TextPainter(
                text: TextSpan(
                  text: String.fromCharCode(codepoint),
                  style: const TextStyle(
                    inherit: false,
                    fontFamily: 'PiliAuroraIcons',
                    fontSize: 96,
                    height: 1,
                    leadingDistribution: TextLeadingDistribution.even,
                    color: Colors.black,
                  ),
                ),
                textDirection: TextDirection.ltr,
              )
              ..layout()
              ..paint(Canvas(recorder), Offset.zero);
        final picture = recorder.endRecording();
        final actual = await alphaPixels(picture);
        painter.dispose();
        picture.dispose();
        expect(actual.any((value) => value != 0), isTrue);
      }
      return;
    }

    final manifest =
        jsonDecode(manifestFile.readAsStringSync()) as Map<String, dynamic>;
    final entries = (manifest['icons'] as List).cast<Map<String, dynamic>>();
    expect(definitions, {
      for (final entry in entries)
        entry['name'] as String: int.parse(
          (entry['codepoint'] as String).substring(2),
          radix: 16,
        ),
    });
    final pixels = <String, List<int>>{};
    for (final entry in entries) {
      final info = await vg.loadPicture(
        SvgStringLoader(
          File('doc/dev/artwork/icons/${entry['source']}').readAsStringSync(),
        ),
        null,
      );
      final svgRecorder = ui.PictureRecorder();
      Canvas(svgRecorder)
        ..scale(4)
        ..drawPicture(info.picture);
      final svgPicture = svgRecorder.endRecording();
      final expected = await alphaPixels(svgPicture);
      info.picture.dispose();
      svgPicture.dispose();

      final recorder = ui.PictureRecorder();
      final painter =
          TextPainter(
              text: TextSpan(
                text: String.fromCharCode(definitions[entry['name']]!),
                style: const TextStyle(
                  inherit: false,
                  fontFamily: 'PiliAuroraIcons',
                  fontSize: 96,
                  height: 1,
                  leadingDistribution: TextLeadingDistribution.even,
                  color: Colors.black,
                ),
              ),
              textDirection: TextDirection.ltr,
            )
            ..layout()
            ..paint(Canvas(recorder), Offset.zero);
      final picture = recorder.endRecording();
      final actual = await alphaPixels(picture);
      painter.dispose();
      picture.dispose();
      var intersection = 0;
      var union = 0;
      for (var i = 0; i < actual.length; i++) {
        intersection += min(actual[i], expected[i]);
        union += max(actual[i], expected[i]);
      }
      expect(union, greaterThan(0), reason: entry['name'] as String);
      // 字体和 SVG 的抗锯齿略有差异，轮廓覆盖仍须高度一致。
      expect(
        intersection / union,
        greaterThan(0.90),
        reason: entry['name'] as String,
      );
      pixels[entry['name'] as String] = actual;
    }
    for (final (outline, filled) in [
      ('motion_photos_on_outlined', 'motion_photos_on'),
      ('player_dm_tip_like', 'player_dm_tip_like_solid'),
      ('star_favorite_line', 'star_favorite_solid'),
    ]) {
      expect(pixels[outline], isNot(orderedEquals(pixels[filled]!)));
    }
  });
}

Future<List<int>> alphaPixels(ui.Picture picture) async {
  final image = await picture.toImage(96, 96);
  final bytes = (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!
      .buffer
      .asUint8List();
  final alpha = [for (var i = 3; i < bytes.length; i += 4) bytes[i]];
  image.dispose();
  return alpha;
}
