import 'dart:ui' as ui;

import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pili_aurora/common/widgets/flutter/vertical_slider.dart';

SemanticsData _sliderData(SemanticsNode root) {
  SemanticsData? result;
  void visit(SemanticsNode node) {
    final data = node.getSemanticsData();
    if (data.flagsCollection.isSlider) {
      result = data;
      return;
    }
    node.visitChildren((child) {
      visit(child);
      return result == null;
    });
  }

  visit(root);
  expect(result, isNotNull, reason: 'slider semantics node must exist');
  return result!;
}

void main() {
  testWidgets('disabled and empty-range sliders do not expose input focus', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();

    Future<void> pumpSlider({required bool enabled, bool emptyRange = false}) {
      return tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: VerticalSlider(
                value: emptyRange ? 0 : 0.5,
                max: emptyRange ? 0 : 1,
                onChanged: enabled ? (_) {} : null,
              ),
            ),
          ),
        ),
      );
    }

    await pumpSlider(enabled: false);
    var data = _sliderData(tester.getSemantics(find.byType(VerticalSlider)));
    expect(data.flagsCollection.isFocused, ui.Tristate.none);
    expect(data.hasAction(SemanticsAction.increase), isFalse);

    await pumpSlider(enabled: true);
    data = _sliderData(tester.getSemantics(find.byType(VerticalSlider)));
    expect(data.flagsCollection.isFocused, ui.Tristate.isFalse);
    expect(data.hasAction(SemanticsAction.increase), isTrue);

    await pumpSlider(enabled: true, emptyRange: true);
    data = _sliderData(tester.getSemantics(find.byType(VerticalSlider)));
    expect(data.flagsCollection.isFocused, ui.Tristate.none);
    expect(data.hasAction(SemanticsAction.increase), isFalse);
    semantics.dispose();
  });
}
