import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pili_aurora/http/api.dart';
import 'package:pili_aurora/http/init.dart';
import 'package:pili_aurora/http/loading_state.dart';
import 'package:pili_aurora/http/member.dart';
import 'package:pili_aurora/http/retry_interceptor.dart';
import 'package:pili_aurora/models/common/account_type.dart';
import 'package:pili_aurora/models/common/member/contribute_type.dart';
import 'package:pili_aurora/models/common/member/web_ss_type.dart';
import 'package:pili_aurora/utils/accounts.dart';
import 'package:pili_aurora/utils/accounts/account.dart';
import 'package:pili_aurora/utils/storage.dart';
import 'package:pili_aurora/utils/storage_key.dart';

import '../support/memory_box.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  Account account(int id) => LoginAccount(
    BiliCookieJar.fromJson({'DedeUserID': '$id', 'bili_jct': 'fixture-$id'}),
    null,
    null,
  );
  final original = account(1);
  final replacement = account(2);
  final requests = <RequestOptions>[];
  Object? body;
  DioExceptionType? failureType;
  DioException? lastFailure;
  var switchWhileSigning = false;
  setUpAll(() {
    GStorage.setting = MemoryBox();
    GStorage.video = MemoryBox();
    GStorage.localCache = MemoryBox();
    Request();
    Request.dio.interceptors
      ..clear()
      ..add(RetryInterceptor(Request.dio, 2, 0))
      ..add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            requests.add(options);
            if (switchWhileSigning && options.path == Api.userInfo) {
              Accounts.accountMode[AccountType.main.index] = replacement;
              handler.resolve(
                Response(
                  requestOptions: options,
                  data: {
                    'code': 0,
                    'data': {
                      'wbi_img': {
                        'img_url': 'https://example.invalid/${'a' * 32}.png',
                        'sub_url': 'https://example.invalid/${'b' * 32}.png',
                      },
                    },
                  },
                ),
              );
            } else if (failureType case final type?) {
              final error = lastFailure = DioException(
                requestOptions: options,
                type: type,
              );
              handler.reject(error, true);
            } else {
              handler.resolve(Response(requestOptions: options, data: body));
            }
          },
        ),
      );
  });
  setUp(() async {
    Accounts.accountMode[AccountType.main.index] = original;
    await GStorage.localCache.putAll({
      LocalCacheKey.mixinKey: 'fixture',
      LocalCacheKey.timeStamp: DateTime.now().millisecondsSinceEpoch,
    });
    requests.clear();
    body = null;
    failureType = null;
    lastFailure = null;
    switchWhileSigning = false;
  });
  tearDownAll(() => Request.dio.close(force: true));

  final queries = <String, Future<LoadingState<dynamic>> Function()>{
    'article': () =>
        MemberHttp.spaceArticle(account: original, mid: 3, page: 1),
    'series': () =>
        MemberHttp.seasonSeriesList(account: original, mid: 3, pn: 1),
    'archive': () =>
        MemberHttp.spaceArchive(type: ContributeType.video, mid: 3, pn: 1),
    'audio': () => MemberHttp.spaceAudio(account: original, mid: 3, page: 1),
    'cheese': () => MemberHttp.spaceCheese(account: original, mid: 3, page: 1),
    'space': () => MemberHttp.space(mid: 3),
    'info': () => MemberHttp.memberInfo(mid: 3),
    'stat': () => MemberHttp.memberStat(mid: 3),
    'card': () => MemberHttp.memberCardInfo(account: original, mid: 3),
    'searchArchive': () => MemberHttp.searchArchive(mid: 3, pn: 1),
    'seriesWeb': () => MemberHttp.seasonSeriesWeb(
      type: WebSsType.series,
      mid: 3,
      id: 4,
      pn: 1,
    ),
    'dynSearch': () => MemberHttp.dynSearch(
      account: original,
      mid: 3,
      pn: 1,
      offset: '',
      keyword: '关键词',
    ),
    'tags': () => MemberHttp.followUpTags(account: original),
    'group': () =>
        MemberHttp.followUpGroup(account: original, mid: 3, tagid: 4, pn: 1),
    'view': () => MemberHttp.memberView(mid: 3),
    'followSearch': () => MemberHttp.followSearch(
      account: original,
      mid: 3,
      ps: 20,
      pn: 1,
      name: '关键词',
    ),
    'opus': () => MemberHttp.spaceOpus(hostMid: 3, page: 1),
    'upower': () => MemberHttp.upowerRank(account: original, upMid: 3, page: 1),
    'coin': () => MemberHttp.coinArc(account: original, mid: 3, page: 1),
    'like': () => MemberHttp.likeArc(account: original, mid: 3, page: 1),
    'shop': () => MemberHttp.spaceShop(account: original, mid: 3),
    'guard': () => MemberHttp.memberGuard(account: original, ruid: 3, page: 1),
  };

  test('成员22类查询保留业务拒绝、错误码与原账号', () async {
    body = {'code': -667777, 'message': '无访问权限'};
    for (final query in queries.entries) {
      final failure = await query.value() as Error;
      expect(failure.code, -667777, reason: query.key);
      expect(failure.toString(), '无访问权限', reason: query.key);
      expect(failure, isNot(isA<UnknownResult>()));
      expect(requests.last.extra['account'], same(original));
      expect(requests.last.extra['noRetry'], isFalse);
    }
  });

  test('损坏查询响应与传输失败均沿结果交付并保留原因和堆栈', () async {
    body = {'code': 0, 'data': 'private response'};
    for (final query in queries.entries) {
      final failure = await query.value() as Error;
      expect(failure, isNot(isA<UnknownResult>()), reason: query.key);
      expect(failure.cause, isNotNull, reason: query.key);
      expect(failure.stackTrace, isNotNull);
      expect(failure.toString(), isNot(contains('private response')));
    }
    failureType = DioExceptionType.receiveTimeout;
    for (final query in queries.entries) {
      final failure = await query.value() as Error;
      expect(failure.cause, same(lastFailure), reason: query.key);
      expect(failure.stackTrace, isNotNull);
    }
  });

  test('领域空对象、分组空列表及合集缺失保留原空语义', () async {
    for (final query in queries.entries) {
      body = {
        'code': 0,
        'data': switch (query.key) {
          'tags' || 'group' => <Object>[],
          'guard' => {'guard_top_list': <Object>[]},
          'info' => {'vip': <String, dynamic>{}},
          _ => <String, dynamic>{},
        },
      };
      expect((await query.value()).isSuccess, isTrue, reason: query.key);
    }
    body = {'code': 0};
    expect(
      (await MemberHttp.followUpGroup(
        account: original,
        mid: 3,
        tagid: 4,
        pn: 1,
      )).data.list,
      isEmpty,
    );
    final series = (await MemberHttp.seasonSeriesList(
      account: original,
      mid: 3,
      pn: 1,
    )).data;
    expect(series.seasonsList, isNull);
    expect(series.seriesList, isNull);
  });

  test('成员签名期间切号仍使用发起账号，签名准备异常不会逃逸', () async {
    for (final name in ['info', 'searchArchive', 'followSearch', 'opus']) {
      await GStorage.localCache.clear();
      Accounts.accountMode[AccountType.main.index] = original;
      switchWhileSigning = true;
      body = {
        'code': 0,
        'data': {'vip': <String, dynamic>{}},
      };
      expect((await queries[name]!()).isSuccess, isTrue, reason: name);
      expect(Accounts.main, same(replacement));
      expect(requests.last.extra['account'], same(original), reason: name);
      expect(requests.last.queryParameters['w_rid'], isA<String>());
    }
    switchWhileSigning = false;
    requests.clear();
    await GStorage.localCache.put(LocalCacheKey.timeStamp, 'invalid timestamp');
    for (final name in ['info', 'searchArchive', 'followSearch', 'opus']) {
      final failure = await queries[name]!() as Error;
      expect(failure.cause, isNotNull, reason: name);
      expect(failure.stackTrace, isNotNull);
    }
    expect(requests, isEmpty);
  });

  test('商品 POST 仍是查询，可安全重试，失败不会变成待确认', () async {
    failureType = DioExceptionType.connectionError;
    final failure =
        await MemberHttp.spaceShop(account: original, mid: 3) as Error;
    expect(failure, isNot(isA<UnknownResult>()));
    expect(failure.cause, same(lastFailure));
    expect(requests, hasLength(3));
    expect(
      requests.every((r) => r.method == 'POST' && r.extra['noRetry'] == false),
      isTrue,
    );
  });
}
