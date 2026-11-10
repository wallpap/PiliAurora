import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:pili_aurora/http/api.dart';
import 'package:pili_aurora/http/init.dart';
import 'package:pili_aurora/http/loading_state.dart';
import 'package:pili_aurora/models/common/account_type.dart';
import 'package:pili_aurora/pages/emote/controller.dart';
import 'package:pili_aurora/models/remote/emote/emote.dart';
import 'package:pili_aurora/utils/storage_key.dart';
import 'package:pili_aurora/utils/accounts.dart';
import 'package:pili_aurora/utils/accounts/account.dart';
import 'package:pili_aurora/utils/storage.dart';

import '../../support/controlled_interceptor.dart';
import '../../support/memory_box.dart';

class _Emotes extends EmotePanelController {
  final queries = <Future<void>>[];

  @override
  Future<void> queryData([bool isRefresh = true]) {
    final query = super.queryData(isRefresh);
    queries.add(query);
    return query;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final interceptor = ControlledInterceptor();
  final requests = interceptor.requests;
  final cache = _FailingCache();
  LoginAccount account(String csrf) => LoginAccount(
    BiliCookieJar.fromJson({'DedeUserID': '1', 'bili_jct': csrf}),
    null,
    null,
  );
  Map<String, dynamic> emotes(String cover) => {
    'code': 0,
    'data': {
      'packages': [
        {'text': cover},
      ],
    },
  };

  setUpAll(() {
    GStorage.setting = MemoryBox();
    GStorage.video = MemoryBox();
    GStorage.localCache = cache;
    Request();
    Request.dio.interceptors
      ..clear()
      ..add(interceptor);
  });
  tearDownAll(() async {
    Request.dio.close(force: true);
    await interceptor.close();
  });

  test('评论表情绑定主账号，凭据替换后拒绝旧结果并释放旧页签', () async {
    final original = account('original');
    Accounts.accountMode[AccountType.main.index] = original;
    final controller = _Emotes()..onInit();
    addTearDown(() {
      if (!controller.isClosed) controller.onDelete();
    });
    await interceptor.waitForRequests(1);
    expect(requests.single.options.path, Api.myEmote);
    expect(requests.single.options.extra['account'], same(original));
    final replacement = account('replacement');
    Accounts.replaceCredentials(replacement);
    await interceptor.waitForRequests(2);
    expect(requests.last.options.extra['account'], same(replacement));
    requests.last.reply.complete(emotes('new'));
    await controller.queries[1];
    final refresh = controller.onRefresh();
    await interceptor.waitForRequests(3);
    expect(controller.loadingState.value.data?.single.text, 'new');
    final previousTabs = controller.tabController!;
    requests.last.reply.complete(emotes('refreshed'));
    await refresh;
    expect(previousTabs.animation, isNull);
    requests.first.reply.complete(emotes('old'));
    await controller.queries.first;
    expect(
      controller.loadingState.value.data?.single.text,
      'refreshed',
    );
    expect(controller.loadingState.value, isA<Success>());
    final lastTabs = controller.tabController!;
    controller.onDelete();
    expect(lastTabs.animation, isNull);
    Accounts.replaceCredentials(account('after-close'));
    expect(requests, hasLength(3));
  });
  for (final history in [
    'invalid',
    [
      12,
      {'text': 7},
      {'text': 'valid', 'width': 24},
    ],
  ]) {
    test('损坏历史缓存不阻止表情查询：$history', () async {
      requests.clear();
      cache.data[LocalCacheKey.recentEmotes] = history;
      final controller = _Emotes()..onInit();
      await interceptor.waitForRequests(1);
      requests.single.reply.complete(emotes('available'));
      await controller.queries.single;
      expect(controller.loadingState.value, isA<Success>());
      expect(controller.recentEmotes.length, history is List ? 1 : 0);
      controller.onDelete();
    });
  }

  test('连续选择按顺序保存各自快照，最后保留最新历史', () async {
    final gate = Completer<void>();
    cache.gate = gate;
    final controller = _Emotes();
    final first = controller.recordEmote(Emote(text: 'first'), 24);
    final second = controller.recordEmote(Emote(text: 'second'), 24);
    await Future<void>.delayed(Duration.zero);
    expect(cache.gate, isNull);
    var secondDone = false;
    unawaited(second.then((_) => secondDone = true));
    expect(secondDone, false);
    gate.complete();
    await Future.wait([first, second]);
    final history = cache.get(LocalCacheKey.recentEmotes) as List;
    expect(history.map((item) => item['text']), ['second', 'first']);
    controller.onDelete();
  });

  test('历史保存失败被消费，后续选择仍可保存', () async {
    cache
      ..failNext = true
      ..writes = 0;
    final controller = _Emotes();
    await controller.recordEmote(Emote(text: 'first'), 24);
    await controller.recordEmote(Emote(text: 'second'), 24);
    expect(controller.recentEmotes.first.emote.text, 'second');
    expect((GStorage.localCache as _FailingCache).writes, 2);
    expect(
      (GStorage.localCache.get(LocalCacheKey.recentEmotes) as List).length,
      2,
    );
    controller.onDelete();
  });
}

class _FailingCache extends MemoryBox {
  int writes = 0;
  bool failNext = false;
  Completer<void>? gate;
  @override
  Future<void> put(dynamic key, dynamic value) async {
    writes++;
    final pending = gate;
    gate = null;
    if (pending != null) await pending.future;
    if (failNext) {
      failNext = false;
      throw StateError('cache unavailable');
    }
    await super.put(key, value);
  }
}
