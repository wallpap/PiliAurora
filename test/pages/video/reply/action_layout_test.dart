import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pili_aurora/grpc/bilibili/main/community/reply/v1.pb.dart';
import 'package:pili_aurora/pages/video/reply/widgets/reply_item_grpc.dart';

void main() {
  for (final width in [240.0, 252.862, 320.0]) {
    testWidgets('comment actions fit fractional panel width $width', (
      tester,
    ) async {
      final control = ReplyControl(
        cardLabels: [ReplyCardLabel(textContent: 'UP主觉得很赞')],
      );
      final item = ReplyItemGrpc(
        replyItem: ReplyInfo(replyControl: control),
        replyLevel: 1,
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: width,
                child: Builder(
                  builder: (context) => item.buttonAction(
                    context,
                    Theme.of(context).colorScheme,
                    control,
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      expect(tester.takeException(), isNull);
      expect(find.text('回复'), findsOneWidget);
      expect(find.text('UP主觉得很赞'), findsOneWidget);
    });
  }
}
