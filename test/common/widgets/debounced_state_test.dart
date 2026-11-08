import 'package:pili_aurora/common/widgets/debounced_state.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

class _Harness<T> with DebounceStreamMixin<T> {
  _Harness([this.duration = const Duration(milliseconds: 200)]);
  @override
  final Duration duration;
  final values = <T>[];
  @override
  void onValueChanged(T value) => values.add(value);
}

class _DebouncedWidget extends StatefulWidget {
  const _DebouncedWidget(this.values);
  final List<String> values;
  @override
  State<_DebouncedWidget> createState() => _DebouncedWidgetState();
}

class _DebouncedWidgetState
    extends DebounceStreamState<_DebouncedWidget, String> {
  @override
  Duration get duration => const Duration(milliseconds: 300);
  @override
  void initState() {
    super.initState();
    ctr!.add('value');
  }

  @override
  void onValueChanged(String value) => widget.values.add(value);
  @override
  Widget build(BuildContext context) => const SizedBox();
}

void main() {
  testWidgets('突发输入只交付静默期后的最后值，null 也是有效结果', (tester) async {
    final harness = _Harness<String?>()..subInit();
    try {
      harness.ctr!.add('old');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      harness.ctr!.add(null);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 199));
      expect(harness.values, isEmpty);
      await tester.pump(const Duration(milliseconds: 1));
      expect(harness.values, [null]);
    } finally {
      harness.subDispose();
    }
  });

  testWidgets('重建订阅隔离旧计时器，重复释放丢弃待处理及排队值', (tester) async {
    final harness = _Harness<String>()..subInit();
    try {
      harness.ctr!.add('old');
      await tester.pump();
      harness.ctr!.add('old queued');
      harness.subInit();
      // 先经过一个完整静默期，避免新输入恰好取消旧计时器而掩盖订阅泄漏。
      await tester.pump();
      await tester.pump(harness.duration);
      expect(harness.values, isEmpty);
      harness.ctr!.add('new');
      await tester.pump();
      await tester.pump(harness.duration);
      expect(harness.values, ['new']);

      harness.ctr!.add('pending');
      await tester.pump();
      harness.ctr!.add('queued');
      harness
        ..subDispose()
        ..subDispose();
      await tester.pump(const Duration(seconds: 1));
      expect(harness.values, ['new']);
      expect(harness.ctr, isNull);
    } finally {
      harness.subDispose();
    }
  });

  testWidgets('State 使用自定义延迟，卸载时取消待交付回调', (tester) async {
    final values = <String>[];
    await tester.pumpWidget(_DebouncedWidget(values));
    await tester.pump(const Duration(milliseconds: 299));
    expect(values, isEmpty);
    await tester.pump(const Duration(milliseconds: 1));
    expect(values, ['value']);

    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(_DebouncedWidget(values));
    await tester.pump(const Duration(milliseconds: 299));
    expect(values, ['value']);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 1));
    expect(values, ['value']);
  });
}
