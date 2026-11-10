import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pili_aurora/utils/screenshot.dart';

void main() {
  Future<BuildContext> mount(WidgetTester tester) async {
    late BuildContext context;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (value) {
            context = value;
            return const SizedBox();
          },
        ),
      ),
    );
    return context;
  }

  testWidgets('截图成功卸载离屏树，图片仍由调用方持有', (tester) async {
    final context = await mount(tester);
    final lifecycle = <String>[];
    final image = await tester.runAsync(
      () => Screenshot.screenshot(
        context,
        _Probe(lifecycle: lifecycle),
        constraints: const BoxConstraints.tightFor(width: 20, height: 10),
        pixelRatio: 2,
      ),
    );
    expect(lifecycle, ['init', 'dispose']);
    expect(image!.width, 40);
    expect(image.height, 20);
    try {
      expect(
        await tester.runAsync(() => image.toByteData(format: .png)),
        isNotNull,
      );
    } finally {
      image.dispose();
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('等待资源失败保留原异常，并卸载已创建的离屏树', (tester) async {
    final context = await mount(tester);
    final lifecycle = <String>[];
    final failure = StateError('resource failure');
    final stack = StackTrace.current;
    Object? caught;
    StackTrace? caughtStack;
    await tester.runAsync(() async {
      try {
        await Screenshot.screenshot(
          context,
          _Probe(lifecycle: lifecycle),
          constraints: const BoxConstraints.tightFor(width: 20, height: 10),
          future: () => Future<void>.error(failure, stack),
        );
      } catch (error, trace) {
        caught = error;
        caughtStack = trace;
      }
    });
    expect(caught, same(failure));
    expect(caughtStack, same(stack));
    expect(lifecycle, ['init', 'dispose']);
    expect(tester.takeException(), isNull);
  });

  testWidgets('等待期间更新离屏内容后仍可截图并释放', (tester) async {
    final context = await mount(tester);
    final lifecycle = <String>[];
    late VoidCallback changeColor;
    final image = await tester.runAsync(
      () => Screenshot.screenshot(
        context,
        _Probe(
          lifecycle: lifecycle,
          onReady: (callback) => changeColor = callback,
        ),
        constraints: const BoxConstraints.tightFor(width: 20, height: 10),
        future: () async => changeColor(),
      ),
    );
    try {
      final bytes = await tester.runAsync(() => image!.toByteData());
      expect(bytes!.getUint32(0), 0xff0000ff);
      expect(lifecycle, ['init', 'dispose']);
    } finally {
      image!.dispose();
    }
    expect(tester.takeException(), isNull);
  });
}

class _Probe extends StatefulWidget {
  const _Probe({required this.lifecycle, this.onReady});

  final List<String> lifecycle;
  final void Function(VoidCallback)? onReady;

  @override
  State<_Probe> createState() => _ProbeState();
}

class _ProbeState extends State<_Probe> {
  ui.Color color = Colors.white;

  @override
  void initState() {
    super.initState();
    widget.lifecycle.add('init');
    widget.onReady?.call(changeColor);
  }

  void changeColor() => setState(() => color = const Color(0xffff0000));

  @override
  void dispose() {
    widget.lifecycle.add('dispose');
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ColoredBox(color: color);
}
