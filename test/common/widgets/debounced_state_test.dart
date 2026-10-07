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
  testWidgets('stream mixin collapses a burst to the latest value', (
    tester,
  ) async {
    final harness = _Harness<String>()..subInit();
    harness.ctr!.add('old');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    harness.ctr!.add('new');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 199));
    expect(harness.values, isEmpty);
    await tester.pump(const Duration(milliseconds: 1));
    expect(harness.values, ['new']);
    harness.subDispose();
    await tester.pump();
  });

  testWidgets('disposing drops pending and queued values', (tester) async {
    final harness = _Harness<String>()..subInit();
    harness.ctr!.add('pending');
    await tester.pump();
    harness.ctr!.add('queued');
    harness
      ..subDispose()
      ..subDispose();
    await tester.pump(const Duration(seconds: 1));
    expect(harness.values, isEmpty);
    expect(harness.ctr, isNull);
  });

  testWidgets('reinitializing cancels the old subscription and timer', (
    tester,
  ) async {
    final harness = _Harness<String>()..subInit();
    harness.ctr!.add('old');
    await tester.pump();
    harness.subInit();
    harness.ctr!.add('new');
    await tester.pump();
    await tester.pump(harness.duration);
    expect(harness.values, ['new']);
    harness.subDispose();
    await tester.pump();
  });

  testWidgets('nullable values are not treated as a missing pending value', (
    tester,
  ) async {
    final harness = _Harness<String?>()..subInit();
    harness.ctr!.add(null);
    await tester.pump();
    await tester.pump(harness.duration);
    expect(harness.values, [null]);
    harness.subDispose();
    await tester.pump();
  });

  testWidgets('state uses the overridden duration', (tester) async {
    final values = <String>[];
    await tester.pumpWidget(_DebouncedWidget(values));
    await tester.pump(const Duration(milliseconds: 299));
    expect(values, isEmpty);
    await tester.pump(const Duration(milliseconds: 1));
    expect(values, ['value']);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('unmounting cancels a state pending callback', (tester) async {
    final values = <String>[];
    await tester.pumpWidget(_DebouncedWidget(values));
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 1));
    expect(values, isEmpty);
  });
}
