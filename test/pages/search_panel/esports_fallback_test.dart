import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pili_aurora/models/search/result.dart';
import 'package:pili_aurora/models/search/search_esports.dart';
import 'package:pili_aurora/pages/search_panel/all/widgets/esports.dart';

void main() {
  test('损坏的赛事卡片不阻止其余综合搜索结果解析', () {
    final result = SearchVideoData.fromSearchAll({
      'numResults': 1,
      'result': [
        {
          'result_type': 'esports',
          'data': [
            {'contest': 'invalid'},
          ],
        },
        {'result_type': 'video', 'data': []},
      ],
    });
    expect(result.searchEsports, isNull);
    expect(result.list, isEmpty);
  });

  testWidgets('空赛事列表安全隐藏卡片', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SearchEsportsItem(item: SearchEsports(contest: [])),
        ),
      ),
    );
    expect(tester.takeException(), isNull);
    expect(find.byType(FilledButton), findsNothing);
  });
}
