import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';

void main() {
  testWidgets('Font Awesome 发布版能通过 IconData 接口渲染应用图标', (tester) async {
    // 11.x 以组合代替继承 final IconData；应用的现有组件仍接收 IconData。
    const icons = [
      FontAwesomeIcons.arrowLeft,
      FontAwesomeIcons.b,
      FontAwesomeIcons.circleDown,
      FontAwesomeIcons.circlePlay,
      FontAwesomeIcons.clock,
      FontAwesomeIcons.comment,
      FontAwesomeIcons.ghost,
      FontAwesomeIcons.house,
      FontAwesomeIcons.lock,
      FontAwesomeIcons.lockOpen,
      FontAwesomeIcons.shareFromSquare,
      FontAwesomeIcons.solidClock,
      FontAwesomeIcons.solidStar,
      FontAwesomeIcons.solidThumbsDown,
      FontAwesomeIcons.solidThumbsUp,
      FontAwesomeIcons.star,
      FontAwesomeIcons.thumbsDown,
      FontAwesomeIcons.thumbsUp,
    ];
    for (final icon in icons) {
      expect(icon.data.fontPackage, 'font_awesome_flutter');
      expect(icon.data.fontFamily, isNotEmpty);
    }
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: Wrap(children: [for (final icon in icons) Icon(icon.data)]),
      ),
    );
    expect(find.byType(Icon), findsNWidgets(icons.length));
    expect(tester.takeException(), isNull);
  });
}
