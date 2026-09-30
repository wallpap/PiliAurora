// ignore_for_file: avoid_print

import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';

// 原生 Paragraph 的微基准。显式运行，不加入常规测试目录。
// flutter test --no-pub tool/paragraph_probe_test.dart --reporter expanded
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('chapter text creation versus retained paragraphs', () {
    final titles = List.generate(20, (i) => '章节 $i：合成标题');
    ui.Paragraph paragraph(String title) =>
        (ui.ParagraphBuilder(
          ui.ParagraphStyle(textDirection: ui.TextDirection.ltr, fontSize: 10),
        )..addText(title)).build()..layout(
          const ui.ParagraphConstraints(width: double.infinity),
        );
    final cached = titles.map(paragraph).toList();
    try {
      for (final reuse in [false, true]) {
        final samples = <double>[];
        for (var round = 0; round < 13; round++) {
          final recorder = ui.PictureRecorder();
          final canvas = ui.Canvas(recorder);
          final watch = Stopwatch()..start();
          for (var frame = 0; frame < 100; frame++) {
            for (var i = 0; i < titles.length; i++) {
              final text = reuse ? cached[i] : paragraph(titles[i]);
              canvas.drawParagraph(text, ui.Offset(i * 10, 0));
              if (!reuse) text.dispose();
            }
          }
          watch.stop();
          recorder.endRecording().dispose();
          if (round >= 3) samples.add(watch.elapsedMicroseconds / 1000);
        }
        samples.sort();
        final median = (samples[4] + samples[5]) / 2;
        print(
          'paragraph ${reuse ? "cached" : "uncached"}: '
          'median ${median.toStringAsFixed(3)} ms / 100 paints, '
          'max ${samples.last.toStringAsFixed(3)} ms',
        );
      }
    } finally {
      for (final text in cached) {
        text.dispose();
      }
    }
  });
}
