import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:pili_aurora/plugin/pl_player/playback/playback_session.dart';

void main() {
  test('新查询立即执行，迟到响应和旧任务收尾不影响最新查询', () async {
    final session = PlaybackSession();
    final owner = session.attach();
    final first = Completer<void>();
    final second = Completer<void>();
    final committed = <int>[];
    final old = owner.query((isCurrent) async {
      await first.future;
      if (isCurrent()) committed.add(1);
    }, isValid: () => true);
    final current = owner.query((isCurrent) async {
      await second.future;
      if (isCurrent()) committed.add(2);
    }, isValid: () => true);
    first.complete();
    await old;
    expect(owner.isQuerying, isTrue);
    expect(committed, isEmpty);
    second.complete();
    await current;
    expect(committed, [2]);
    expect(owner.isQuerying, isFalse);
    session.dispose();
  });

  test('页面关闭后查询不能提交，也不能向共享播放器加载', () async {
    final session = PlaybackSession();
    final previous = session.attach();
    final owner = session.attach();
    final response = Completer<void>();
    var loads = 0;
    final query = owner.query((isCurrent) async {
      await response.future;
      if (isCurrent()) {
        await session.load(owner, (_) async => loads++);
      }
    }, isValid: () => true);
    owner.close();
    response.complete();
    await query;
    await session.load(owner, (_) async => loads++);
    expect(loads, 0);
    expect(previous.isActive, isTrue);
    session.dispose();
  });

  test('返回上一页面不会重新激活进入下一页面之前的查询', () async {
    final session = PlaybackSession();
    final previous = session.attach();
    final response = Completer<void>();
    final previousGuard = previous.guard();
    var committed = false;
    final query = previous.query((isCurrent) async {
      await response.future;
      committed = isCurrent();
    }, isValid: () => true);
    final next = session.attach();
    previous.activate();
    response.complete();
    await query;
    expect(committed, isFalse);
    expect(previous.isActive, isTrue);
    expect(previousGuard(), isFalse);
    expect(next.isActive, isFalse);
    next.close();
    expect(previous.isActive, isTrue);
    session.dispose();
  });

  test('连续切源保持互斥，只执行在途任务和最后一次排队任务', () async {
    final session = PlaybackSession();
    final owner = session.attach();
    final opened = Completer<void>();
    final started = Completer<void>();
    final calls = <int>[];
    final first = session.load(owner, (isCurrent) async {
      calls.add(0);
      started.complete();
      await opened.future;
      expect(isCurrent(), isFalse);
    });
    await started.future;
    final queued = [
      for (var i = 1; i <= 100; i++)
        session.load(owner, (_) async => calls.add(i)),
    ];
    expect(session.isLoading, isTrue);
    opened.complete();
    await Future.wait([first, ...queued]);
    expect(calls, [0, 100]);
    expect(session.isLoading, isFalse);
    session.dispose();
  });

  test('新页面加载等待旧原生操作完成，旧请求失去发布权', () async {
    final session = PlaybackSession();
    final previous = session.attach();
    final opened = Completer<void>();
    final started = Completer<void>();
    final calls = <String>[];
    final old = session.load(previous, (isCurrent) async {
      calls.add('old.open');
      started.complete();
      await opened.future;
      if (isCurrent()) calls.add('old.play');
    });
    await started.future;
    final next = session.attach();
    final load = session.load(next, (_) async => calls.add('new.open'));
    expect(calls, ['old.open']);
    opened.complete();
    await Future.wait([old, load]);
    expect(calls, ['old.open', 'new.open']);
    session.dispose();
  });

  test('释放资源等待在途操作结束，重载失败不会阻断后续加载', () async {
    final session = PlaybackSession();
    final owner = session.attach();
    await expectLater(
      session.reload((_) async => throw StateError('reload')),
      throwsStateError,
    );
    final opened = Completer<void>();
    final started = Completer<void>();
    final load = session.load(owner, (isCurrent) async {
      started.complete();
      await opened.future;
      expect(isCurrent(), isFalse);
    });
    await started.future;
    session.dispose();
    var drained = false;
    final drain = session.drained.then((_) => drained = true);
    await Future<void>.value();
    expect(drained, isFalse);
    opened.complete();
    await Future.wait([load, drain]);
    expect(drained, isTrue);
    expect(session.reload((_) async {}), isNull);
  });
}
