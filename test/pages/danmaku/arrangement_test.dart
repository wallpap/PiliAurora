import 'package:canvas_danmaku/canvas_danmaku.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pili_aurora/pages/danmaku/arrangement.dart';

DanmakuMeasuredCandidate<String> _item(
  String id,
  int start, {
  double width = 10,
  double height = 20,
  DanmakuItemType type = DanmakuItemType.scroll,
  int weight = 0,
  bool self = false,
}) => DanmakuMeasuredCandidate(
  identity: id,
  sourceUs: start,
  width: width,
  height: height,
  type: type,
  payload: id,
  weight: weight,
  selfSend: self,
);

DanmakuWindowPlanner<String> _planner({
  int tracks = 2,
  int active = 600,
  DanmakuOption option = const DanmakuOption(duration: 1, staticDuration: 1),
}) => DanmakuWindowPlanner(
  option: option,
  width: 100,
  trackHeight: 20,
  trackCount: tracks,
  maxActive: active,
);

bool _prepare(
  DanmakuWindowPlanner<String> planner,
  List<DanmakuMeasuredCandidate<String>> input, {
  int until = 5000000,
}) => planner.prepare(
  input,
  generation: planner.window.generation,
  preparedUntilUs: until,
);

void main() {
  test('twelve display slots take relative weights from highest downward', () {
    for (final weights in [
      [0, 3, 5, 7, 10],
      [0, 1, 2, 3, 4],
    ]) {
      // 分别覆盖轨道不足与活动数量额度不足；输入故意从低权重开始。
      for (final limits in [(12, 600), (40, 12)]) {
        final planner = _planner(tracks: limits.$1, active: limits.$2);
        final counts = [10, 12, 7, 2, 2];
        _prepare(planner, [
          for (var group = 0; group < weights.length; group++)
            for (var i = 0; i < counts[group]; i++)
              _item('${weights[group]}-$i', 0, weight: weights[group]),
        ]);
        final accepted = planner.window.preparedItems
            .where((item) => item.payload.accepted)
            .map((item) => item.payload.candidate)
            .toList();
        final distribution = <int, int>{};
        for (final candidate in accepted) {
          distribution.update(
            candidate.weight,
            (count) => count + 1,
            ifAbsent: () => 1,
          );
        }
        expect(distribution, {
          weights[4]: 2,
          weights[3]: 2,
          weights[2]: 7,
          weights[1]: 1,
        });
        expect(accepted.length, 12);
        expect(
          accepted.singleWhere((item) => item.weight == weights[1]).identity,
          '${weights[1]}-0',
        );
      }
    }
  });

  test(
    'high weights and self sends reserve tracks before earlier low weights',
    () {
      final planner = _planner(tracks: 1);
      _prepare(planner, [_item('low', 0), _item('high', 90000, weight: 10)]);
      expect(
        planner.window.preparedItems
            .where((e) => e.payload.accepted)
            .single
            .identity,
        'high',
      );
      final self = _planner(tracks: 1);
      _prepare(self, [
        _item('high', 0, weight: 11),
        _item('self', 90000, self: true),
      ]);
      expect(
        self.window.preparedItems
            .where((e) => e.payload.accepted)
            .single
            .identity,
        'self',
      );
    },
  );

  test('preparation carries collision state across batches and evaluates original media time', () {
    final planner = _planner();
    _prepare(planner, [_item('first', 0)]);
    _prepare(planner, [_item('fast', 400000, width: 100)]);
    final items = planner.window.visibleAt(600000)!;
    expect(items.map((e) => e.payload.track), [0, 1]);
    expect(items.first.payload.xAt(600000), closeTo(34, 0.0001));
    expect(items.last.payload.xAt(600000), closeTo(60, 0.0001));
    expect(items.first.endUs, 1000000);
  });

  test(
    'future items use simultaneous lifetime quota rather than window total',
    () {
      final planner = _planner(
        active: 1,
        option: const DanmakuOption(duration: 1, massiveMode: true),
      );
      _prepare(planner, [
        _item('a', 0),
        _item('b', 2000000),
        _item('rejected', 2100000),
      ]);
      final decisions = planner.window.preparedItems;
      expect(decisions.map((e) => e.payload.accepted), [true, true, false]);
      expect(
        planner.window.visibleAt(2500000)!.single.payload.candidate.payload,
        'b',
      );
    },
  );

  test('late candidate cannot displace an established future trajectory', () {
    final planner = _planner(tracks: 1);
    _prepare(planner, [_item('established', 500000)]);
    final original = planner.window.preparedItems.single.payload.trajectory;
    _prepare(planner, [_item('late', 450000)]);
    expect(planner.window.preparedItems.last.payload.accepted, isTrue);
    final late = planner.window.preparedItems.firstWhere(
      (e) => e.identity == 'late',
    );
    expect(late.payload.accepted, isFalse);
    expect(
      planner.window.preparedItems
          .firstWhere((e) => e.identity == 'established')
          .payload
          .trajectory,
      same(original),
    );
  });

  test('expanded static placement blocks every covered track', () {
    final planner = _planner();
    _prepare(planner, [
      _item('large', 0, width: 100, height: 40, type: DanmakuItemType.top),
      _item('scroll', 10000),
    ]);
    expect(planner.window.preparedItems.map((e) => e.payload.accepted), [
      true,
      false,
    ]);
  });

  test('bottom placement and wide static fallback follow existing options', () {
    final bottom = _planner(tracks: 3);
    _prepare(bottom, [_item('bottom', 0, type: DanmakuItemType.bottom)]);
    expect(bottom.window.preparedItems.single.payload.track, 2);
    final fallback = _planner(
      option: const DanmakuOption(duration: 1, static2Scroll: true),
    );
    _prepare(fallback, [
      _item('wide', 0, width: 200, type: DanmakuItemType.top),
    ]);
    expect(fallback.window.preparedItems.single.payload.scrolling, isTrue);
  });

  test('fixed speed retains a wide item for its actual extended lifetime', () {
    final planner = _planner(
      option: const DanmakuOption(duration: 1, scrollFixedVelocity: true),
    );
    _prepare(planner, [_item('wide', 0, width: 200)]);
    expect(planner.window.preparedItems.single.endUs, 3000000);
    planner.window.trimBefore(2000000);
    expect(
      planner.window.visibleAt(2500000)!.single.payload.xAt(2500000),
      -150,
    );
  });
}
