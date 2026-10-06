import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pili_aurora/common/widgets/app_viewport.dart';

void main() {
  test('padding overrides can be released out of order and more than once', () {
    final insets = ViewportInsets();
    final releaseFirst = insets.preserve(const EdgeInsets.all(10));
    final releaseSecond = insets.preserve(const EdgeInsets.all(20));
    expect(insets.padding, const EdgeInsets.all(20));
    releaseFirst();
    expect(insets.padding, const EdgeInsets.all(20));
    releaseFirst();
    releaseSecond();
    expect(insets.padding, isNull);
  });

  test('releasing the latest padding restores an older active override', () {
    final insets = ViewportInsets();
    final releaseFirst = insets.preserve(const EdgeInsets.all(10));
    final releaseSecond = insets.preserve(const EdgeInsets.all(20));
    releaseSecond();
    expect(insets.padding, const EdgeInsets.all(10));
    releaseFirst();
    expect(insets.padding, isNull);
  });

  for (final scale in [1.0, 2.0]) {
    testWidgets('scales viewport and text independently at $scale', (
      tester,
    ) async {
      const original = MediaQueryData(
        size: Size(800, 600),
        devicePixelRatio: 2,
        padding: EdgeInsets.all(20),
        viewPadding: EdgeInsets.all(24),
        viewInsets: EdgeInsets.only(bottom: 100),
      );
      late MediaQueryData actual;
      await tester.pumpWidget(
        MediaQuery(
          data: original,
          child: AppViewport(
            uiScale: scale,
            textScale: 1.5,
            insets: ViewportInsets(),
            child: Builder(
              builder: (context) {
                actual = MediaQuery.of(context);
                return const SizedBox();
              },
            ),
          ),
        ),
      );
      expect(actual.size, original.size / scale);
      expect(actual.devicePixelRatio, original.devicePixelRatio * scale);
      expect(actual.padding, original.padding / scale);
      expect(actual.viewPadding, original.viewPadding / scale);
      expect(actual.viewInsets, original.viewInsets / scale);
      expect(actual.textScaler.scale(10), 15);
    });
  }

  testWidgets('preserved padding is already in logical pixels', (tester) async {
    final insets = ViewportInsets();
    final release = insets.preserve(const EdgeInsets.all(18));
    late MediaQueryData actual;
    Future<void> build() => tester.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(padding: EdgeInsets.all(20)),
        child: AppViewport(
          uiScale: 2,
          textScale: 1,
          insets: insets,
          child: Builder(
            builder: (context) {
              actual = MediaQuery.of(context);
              return const SizedBox();
            },
          ),
        ),
      ),
    );
    await build();
    expect(actual.padding, const EdgeInsets.all(18));
    expect(actual.viewPadding, const EdgeInsets.all(18));
    release();
    await build();
    expect(actual.padding, const EdgeInsets.all(10));
    expect(actual.viewPadding, EdgeInsets.zero);
  });
}
