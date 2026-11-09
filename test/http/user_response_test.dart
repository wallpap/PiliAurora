import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pili_aurora/http/api.dart';
import 'package:pili_aurora/http/init.dart';
import 'package:pili_aurora/http/loading_state.dart';
import 'package:pili_aurora/http/user.dart';
import 'package:pili_aurora/models/common/account_type.dart';
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
  final main = account(1);
  final history = account(2);
  final replacement = account(3);
  Object? body;
  var failTransport = false;
  var switchWhileSigning = false;
  final requests = <RequestOptions>[];
  final queries = <String, Future<LoadingState<dynamic>> Function()>{
    '资料': UserHttp.userInfo,
    '统计': UserHttp.userStatOwner,
    '稍后再看': () => UserHttp.seeYouLater(page: 1),
    '历史': () => UserHttp.historyList(type: 'all'),
    '历史状态': UserHttp.historyStatus,
    '关系': () => UserHttp.userRelation(1),
    '历史搜索': () => UserHttp.searchHistory(pn: 1, keyword: 'sample'),
    '订阅': () => UserHttp.userSubFolder(mid: 1, pn: 1, ps: 20),
    '标签': () => UserHttp.videoTags(bvid: 'BV1xx411c7mD'),
    '播放列表': () => UserHttp.getMediaList(type: 1, bizId: 1, ps: 20),
    '余额': UserHttp.getCoin,
    '空间设置': () => UserHttp.spaceSetting(account: main),
    '硬币记录': () => UserHttp.coinLog(account: main),
    '登录记录': () => UserHttp.loginLog(account: main),
    '经验记录': () => UserHttp.expLog(account: main),
    '实名': () => UserHttp.getUserRealName(1),
    '关注的人': () => UserHttp.followedUp(mid: 1, account: main, pn: 1),
    '共同关注': () => UserHttp.sameFollowing(mid: 1, account: main, pn: 1),
  };
  final writes = <Future<LoadingState<void>> Function()>[
    () => UserHttp.pauseHistory(true),
    UserHttp.clearHistory,
    () => UserHttp.toViewLater(aid: 42),
    () => UserHttp.toViewDel(aids: '42'),
    UserHttp.toViewClear,
    () => UserHttp.delHistory('archive_42'),
    () => UserHttp.dynamicReport(mid: 1, dynId: 1, reasonType: 1),
    () => UserHttp.spaceSettingMod({}, account: main),
    UserHttp.vipExpAdd,
    () => UserHttp.spaceReserve(sid: 1, isFollow: false),
  ];

  setUpAll(() {
    GStorage.setting = MemoryBox();
    GStorage.video = MemoryBox();
    GStorage.localCache = MemoryBox();
    Request();
    Request.dio.interceptors
      ..clear()
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
            } else if (failTransport) {
              handler.reject(
                DioException(
                  requestOptions: options,
                  type: DioExceptionType.receiveTimeout,
                ),
              );
            } else {
              handler.resolve(Response(requestOptions: options, data: body));
            }
          },
        ),
      );
  });
  setUp(() async {
    Accounts.accountMode[AccountType.main.index] = main;
    Accounts.accountMode[AccountType.heartbeat.index] = history;
    await GStorage.localCache.putAll({
      LocalCacheKey.mixinKey: 'synthetic',
      LocalCacheKey.timeStamp: DateTime.now().millisecondsSinceEpoch,
    });
    requests.clear();
    failTransport = switchWhileSigning = false;
    body = null;
  });
  tearDownAll(() => Request.dio.close(force: true));

  test('账号查询的损坏响应沿结果返回，保留原因且不暴露正文', () async {
    for (final invalid in [
      null,
      [],
      {'code': '0'},
      {'code': 0, 'data': 'private body'},
    ]) {
      body = invalid;
      for (final entry in queries.entries) {
        final result = await entry.value() as Error;
        expect(result.cause, isNotNull, reason: entry.key);
        expect(result.stackTrace, isNotNull, reason: entry.key);
        expect(result.toString(), isNot(contains('private body')));
      }
    }
  });

  test('所有账号接口保留明确拒绝码和 msg 文案', () async {
    body = {'code': -403, 'msg': '请求被拒绝'};
    for (final invoke in [...queries.values, ...writes]) {
      final result = await invoke() as Error;
      expect(result.code, -403);
      expect(result.toString(), '请求被拒绝');
      expect(result, isNot(isA<UnknownResult>()));
    }
  });

  test('写入成功允许空数据，损坏响应和断连保持待确认并禁用重试', () async {
    for (final invoke in writes) {
      body = {'code': 0};
      expect(await invoke(), isA<Success<void>>());
      body = {'code': '0'};
      expect(await invoke(), isA<UnknownResult>());
      failTransport = true;
      final result = await invoke() as UnknownResult;
      expect(result.cause, isA<DioException>());
      expect(requests.last.extra['noRetry'], isTrue);
      final bound = requests.last.extra['account'] as Account;
      final params = {
        ...requests.last.queryParameters,
        ...?requests.last.data as Map?,
      };
      expect(params['csrf'], bound.csrf);
      failTransport = false;
    }
    expect(requests.first.extra['account'], same(history));
  });

  test('空列表和可选余额、标签保留正常空数据语义，历史状态必须是布尔值', () async {
    body = {'code': 0, 'data': <String, dynamic>{}};
    expect((await UserHttp.seeYouLater(page: 1)).data.list, isNull);
    expect((await UserHttp.historyList(type: 'all')).data.list, isNull);
    body = {'code': 0, 'data': null};
    expect((await UserHttp.getCoin()).data, isNull);
    expect((await UserHttp.videoTags(bvid: 'BV1xx411c7mD')).data, isNull);
    expect(await UserHttp.historyStatus(), isA<Error>());
    body = {'code': 0, 'data': false};
    expect((await UserHttp.historyStatus()).data, isFalse);
  });

  test('签名等待期间切号仍绑定发起时的稍后再看账号', () async {
    await GStorage.localCache.clear();
    switchWhileSigning = true;
    body = {'code': 0, 'data': <String, dynamic>{}};
    expect(await UserHttp.seeYouLater(page: 1), isA<Success>());
    expect(requests.last.path, Api.seeYouLater);
    expect(requests.last.extra['account'], same(main));
    expect(Accounts.main, same(replacement));
  });

  test('缺少目标和无效清空类型在本地拒绝，不发送写入', () async {
    expect(await UserHttp.toViewLater(), isA<Error>());
    expect(await UserHttp.toViewDel(aids: ''), isA<Error>());
    expect(await UserHttp.toViewClear(cleanType: 3), isA<Error>());
    expect(await UserHttp.delHistory(''), isA<Error>());
    expect(requests, isEmpty);
  });
}
