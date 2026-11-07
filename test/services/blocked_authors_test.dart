import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pili_aurora/http/api.dart';
import 'package:pili_aurora/http/init.dart';
import 'package:pili_aurora/services/blocked_authors.dart';
import 'package:pili_aurora/services/cooperative_authors.dart';
import 'package:pili_aurora/models/model_video.dart';
import 'package:pili_aurora/utils/accounts.dart';
import 'package:pili_aurora/utils/accounts/account.dart';
import 'package:pili_aurora/utils/global_data.dart';
import 'package:pili_aurora/utils/id_utils.dart';
import 'package:pili_aurora/utils/storage.dart';
import 'package:pili_aurora/utils/storage_pref.dart';
import 'package:pili_aurora/utils/storage_key.dart';

import '../support/memory_box.dart';

typedef _Request = ({
  RequestOptions options,
  RequestInterceptorHandler handler,
});

LoginAccount _account(int mid) => LoginAccount(
  BiliCookieJar.fromJson({'DedeUserID': '$mid', 'bili_jct': 'fixture-csrf'}),
  null,
  null,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late StreamController<_Request> requests;
  late StreamIterator<_Request> iterator;
  late LoginAccount account;
  var accountId = 100;

  setUpAll(() {
    GStorage.setting = MemoryBox();
    GStorage.localCache = MemoryBox();
    Request();
  });
  setUp(() {
    account = _account(accountId++);
    Accounts.accountMode[0] = account;
    requests = StreamController<_Request>();
    iterator = StreamIterator(requests.stream);
    Request.dio.interceptors
      ..clear()
      ..add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            requests.add((options: options, handler: handler));
          },
        ),
      );
  });
  tearDown(() async {
    await iterator.cancel();
    await requests.close();
  });
  tearDownAll(() => Request.dio.close(force: true));

  Future<_Request> next([String path = Api.blackLst]) async {
    expect(await iterator.moveNext(), isTrue);
    final request = iterator.current;
    expect(request.options.path, path);
    return request;
  }

  void respond(_Request request, List<int> mids, int total) {
    request.handler.resolve(
      Response(
        requestOptions: request.options,
        data: {
          'code': 0,
          'data': {
            'total': total,
            'list': mids.map((mid) => {'mid': mid}).toList(),
          },
        },
      ),
    );
  }

  test('合并并发同步，完整读取多页后才更新账号缓存', () async {
    GlobalData().blackMids = {999};
    final loading = BlockedAuthors.ensureLoaded();
    final shared = BlockedAuthors.ensureLoaded();
    final first = await next();
    expect(first.options.extra['account'], same(account));
    expect(first.options.queryParameters['pn'], 1);
    respond(first, List.generate(50, (i) => i + 1), 51);
    final second = await next();
    expect(second.options.queryParameters['pn'], 2);
    expect(GlobalData().blackMids, {999});
    respond(second, [51], 51);
    await Future.wait([loading!, shared!]);
    expect(GlobalData().blackMids, Set.of(List.generate(51, (i) => i + 1)));
    expect(Pref.blackMids, GlobalData().blackMids);
    expect(BlockedAuthors.ensureLoaded(), isNull);
  });

  test('后续页失败时保留完整缓存', () async {
    GlobalData().blackMids = {999};
    Pref.blackMids = {999};
    final loading = BlockedAuthors.ensureLoaded();
    respond(await next(), [7], 2);
    final second = await next();
    second.handler.resolve(
      Response(
        requestOptions: second.options,
        data: {'code': -1, 'message': 'fixture failure'},
      ),
    );
    await loading;
    expect(GlobalData().blackMids, {999});
    expect(Pref.blackMids, {999});
  });

  test('同步期间拉黑和解除操作优先于旧名单', () async {
    GlobalData().blackMids = {7};
    final loading = BlockedAuthors.ensureLoaded();
    final request = await next();
    BlockedAuthors.setBlocked(7, false);
    BlockedAuthors.setBlocked(8, true);
    respond(request, [7, 9], 2);
    await loading;
    expect(GlobalData().blackMids, {8, 9});
    expect(Pref.blackMids, {8, 9});
  });

  test('账号切换隔离缓存及迟到的同步响应', () async {
    BlockedAuthors.setBlocked(7, true);
    final old = BlockedAuthors.ensureLoaded();
    final oldRequest = await next();
    final other = _account(accountId++);
    Accounts.accountMode[0] = other;
    expect(GlobalData().blackMids, isEmpty);
    final current = BlockedAuthors.ensureLoaded();
    final currentRequest = await next();
    respond(currentRequest, [8], 1);
    await current;
    respond(oldRequest, [9], 1);
    await old;
    expect(GlobalData().blackMids, {8});
    Accounts.accountMode[0] = account;
    expect(GlobalData().blackMids, {7});
    Accounts.accountMode[0] = AnonymousAccount();
    expect(GlobalData().blackMids, isEmpty);
    expect(BlockedAuthors.ensureLoaded(), isNull);
  });

  test('真正的空名单清空该账号缓存', () async {
    BlockedAuthors.setBlocked(7, true);
    final loading = BlockedAuthors.ensureLoaded();
    respond(await next(), [], 0);
    await loading;
    expect(GlobalData().blackMids, isEmpty);
    expect(Pref.blackMids, isEmpty);
  });

  test('合作作者补查通过现有详情接口绑定账号并读取staff', () async {
    await GStorage.localCache.put(
      LocalCacheKey.timeStamp,
      DateTime.now().millisecondsSinceEpoch,
    );
    await GStorage.localCache.put(LocalCacheKey.mixinKey, 'fixture-mixin-key');
    final authors = VideoAuthors(isCooperation: true);
    final query = CooperativeAuthors.shared.prepare([
      (aid: 123, bvid: IdUtils.av2bv(123), ownerMid: 8, authors: authors),
    ], isCurrent: () => true);
    final request = await next(Api.videoIntro);
    expect(request.options.extra['account'], same(account));
    expect(request.options.extra['noRetry'], isTrue);
    expect(request.options.queryParameters['bvid'], IdUtils.av2bv(123));
    expect(request.options.queryParameters['w_rid'], isNotEmpty);
    request.handler.resolve(
      Response(
        requestOptions: request.options,
        data: {
          'code': 0,
          'data': {
            'owner': {'mid': 8},
            'staff': [
              {'mid': 8},
              {'mid': '7'},
            ],
          },
        },
      ),
    );
    await query;
    expect(authors.mids, {7, 8});
  });
}
