import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pili_aurora/http/api.dart';
import 'package:pili_aurora/http/init.dart';
import 'package:pili_aurora/http/live.dart';
import 'package:pili_aurora/http/loading_state.dart';
import 'package:pili_aurora/models/common/account_type.dart';
import 'package:pili_aurora/models/common/live/live_contribution_rank_type.dart';
import 'package:pili_aurora/models/common/live/live_search_type.dart';
import 'package:pili_aurora/utils/accounts.dart';
import 'package:pili_aurora/utils/accounts/account.dart';
import 'package:pili_aurora/utils/storage.dart';
import 'package:pili_aurora/utils/storage_key.dart';

import '../support/memory_box.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  Account account(int id) => LoginAccount(
    BiliCookieJar.fromJson({'DedeUserID': '$id', 'bili_jct': 'fixture-$id'}),
    'access-$id',
    null,
  );
  final main = account(1);
  final heartbeat = account(2);
  final recommend = account(3);
  final replacement = account(4);
  Object? body;
  var failTransport = false;
  var switchWhileSigning = false;
  final requests = <RequestOptions>[];
  final queries = <String, Future<LoadingState<dynamic>> Function()>{
    '播放地址': () => LiveHttp.liveRoomInfo(roomId: 12),
    '房间详情': () => LiveHttp.liveRoomInfoH5(roomId: 12),
    '弹幕历史': () => LiveHttp.liveRoomDmPrefetch(roomId: 12),
    '弹幕凭据': () => LiveHttp.liveRoomGetDanmakuToken(roomId: 12),
    '直播表情': () => LiveHttp.getLiveEmoticons(roomId: 12),
    '推荐': () => LiveHttp.liveFeedIndex(pn: 1),
    '关注': () => LiveHttp.liveFollow(1, account: main),
    '分区推荐': () => LiveHttp.liveSecondList(pn: 1, areaId: 1, parentAreaId: 2),
    '分区目录': LiveHttp.liveAreaList,
    '常用标签': () => LiveHttp.getLiveFavTag(account: main),
    '子分区': () => LiveHttp.liveRoomAreaList(parentid: 2),
    '搜索': () => LiveHttp.liveSearch(
      account: recommend,
      page: 1,
      keyword: 'sample',
      type: LiveSearchType.room,
    ),
    '屏蔽规则': () => LiveHttp.getLiveInfoByUser(12),
    '醒目留言': () => LiveHttp.superChatMsg(12),
    '贡献榜': () => LiveHttp.liveContributionRank(
      ruid: 1,
      roomId: 12,
      page: 1,
      type: LiveContributionRankType.online_rank,
    ),
    '大航海榜': () => LiveHttp.liveGuardTopList(roomId: 12, ruid: 1),
    '粉丝勋章': () => LiveHttp.liveMedalWall(mid: 1),
  };
  final writes = <String, Future<LoadingState<dynamic>> Function()>{
    '发送弹幕': () => LiveHttp.sendLiveMsg(roomId: 12, msg: 'sample'),
    '常用标签': () => LiveHttp.setLiveFavTag(ids: '1,2', account: main),
    '屏蔽等级': () => LiveHttp.liveSetSilent(type: 'off', level: 0),
    '添加关键词': () => LiveHttp.addShieldKeyword(keyword: 'sample', account: main),
    '移除关键词': () => LiveHttp.delShieldKeyword(keyword: 'sample', account: main),
    '移除用户': () => LiveHttp.liveShieldUser(uid: 2, roomid: 12, type: 0),
    '点赞': () => LiveHttp.liveLikeReport(clickTime: 1, roomId: 12, uid: 2),
    '弹幕举报': () => LiveHttp.liveDmReport(
      roomId: 12,
      mid: 2,
      msg: 'sample',
      reason: 'other',
      reasonId: 1,
      dmType: 0,
      idStr: '1',
      ts: 0,
      sign: 'synthetic',
    ),
    '醒目留言举报': () => LiveHttp.superChatReport(
      id: 1,
      roomId: 12,
      uid: 2,
      msg: 'sample',
      reason: 'other',
      ts: 0,
      token: 'synthetic',
    ),
    '不感兴趣': () => LiveHttp.liveFeedback(12, 1, 'room'),
  };

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
              for (final type in AccountType.values) {
                Accounts.accountMode[type.index] = replacement;
              }
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
  void restoreAccounts() {
    Accounts.accountMode[AccountType.main.index] = main;
    Accounts.accountMode[AccountType.heartbeat.index] = heartbeat;
    Accounts.accountMode[AccountType.recommend.index] = recommend;
  }

  setUp(() async {
    restoreAccounts();
    await GStorage.localCache.putAll({
      LocalCacheKey.mixinKey: 'synthetic',
      LocalCacheKey.timeStamp: DateTime.now().millisecondsSinceEpoch,
    });
    requests.clear();
    failTransport = switchWhileSigning = false;
    body = null;
  });
  tearDownAll(() => Request.dio.close(force: true));

  test('直播查询的协议损坏沿结果返回并保留诊断原因', () async {
    for (final invalid in [
      null,
      [],
      {'code': '0'},
      {'code': 0, 'data': 'private body'},
    ]) {
      body = invalid;
      for (final entry in queries.entries) {
        final result = await entry.value() as Error;
        expect(result, isNot(isA<UnknownResult>()), reason: entry.key);
        expect(result.cause, isNotNull, reason: entry.key);
        expect(result.stackTrace, isNotNull, reason: entry.key);
        expect(result.toString(), isNot(contains('private body')));
      }
    }
  });

  test('直播全部业务接口保留拒绝码和 msg 文案', () async {
    body = {'code': -403, 'msg': '请求被拒绝'};
    for (final entry in [...queries.entries, ...writes.entries]) {
      final result = await entry.value() as Error;
      expect(result.code, -403, reason: entry.key);
      expect(result.toString(), '请求被拒绝');
      expect(result, isNot(isA<UnknownResult>()));
    }
  });

  test('直播写入允许空确认，损坏响应和断连保持待确认并禁止重试', () async {
    for (final entry in writes.entries) {
      body = {'code': 0};
      expect(await entry.value(), isA<Success>(), reason: entry.key);
      body = {'code': '0'};
      expect(await entry.value(), isA<UnknownResult>(), reason: entry.key);
      failTransport = true;
      final result = await entry.value() as UnknownResult;
      expect(result.cause, isA<DioException>(), reason: entry.key);
      expect(result.stackTrace, isNotNull);
      final request = requests.last;
      expect(request.extra['noRetry'], isTrue, reason: entry.key);
      final bound = request.extra['account'] as Account;
      final payload = request.data;
      if (payload is FormData) {
        expect(Map.fromEntries(payload.fields)['csrf'], bound.csrf);
      } else if (payload is Map && payload.containsKey('csrf')) {
        expect(payload['csrf'], bound.csrf);
      }
      failTransport = false;
    }
    expect(requests.last.method, 'GET');
    expect(requests.last.extra['account'], same(recommend));
    expect(requests.last.queryParameters['access_key'], recommend.accessKey);
  });

  test('直播查询断连保留传输原因与可读提示', () async {
    failTransport = true;
    for (final entry in queries.entries) {
      final result = await entry.value() as Error;
      expect(result, isNot(isA<UnknownResult>()), reason: entry.key);
      expect(result.cause, isA<DioException>(), reason: entry.key);
      expect(result.toString(), '响应超时，请稍后重试！');
    }
  });

  test('直播可选列表和屏蔽信息保留空数据语义', () async {
    body = {'code': 0, 'data': <String, dynamic>{}};
    expect((await LiveHttp.liveRoomDmPrefetch(roomId: 12)).data, isNull);
    expect((await LiveHttp.getLiveEmoticons(roomId: 12)).data, isNull);
    expect((await LiveHttp.liveAreaList()).data, isNull);
    expect((await LiveHttp.getLiveFavTag(account: main)).data, isEmpty);
    expect((await LiveHttp.getLiveInfoByUser(12)).data, isNull);
    expect((await LiveHttp.superChatMsg(12)).data.list, isNull);
    body = {'code': 0, 'data': null};
    expect((await LiveHttp.liveRoomAreaList(parentid: 1)).data, isNull);
    body = {
      'code': 0,
      'data': <String, dynamic>{'tags': 'private body'},
    };
    expect(await LiveHttp.getLiveFavTag(account: main), isA<Error>());
  });

  test('签名等待期间切号仍绑定发起时账号与 CSRF', () async {
    final signed = [
      (invoke: writes['发送弹幕']!, account: main),
      (invoke: queries['播放地址']!, account: heartbeat),
      (invoke: queries['弹幕凭据']!, account: heartbeat),
      (invoke: queries['屏蔽规则']!, account: main),
      (invoke: writes['点赞']!, account: heartbeat),
      (invoke: queries['贡献榜']!, account: main),
    ];
    for (final entry in signed) {
      restoreAccounts();
      await GStorage.localCache.clear();
      switchWhileSigning = true;
      body = {
        'code': 0,
        'data': {'token': 'synthetic', 'host_list': <Object>[]},
      };
      expect(await entry.invoke(), isA<Success>());
      expect(requests.last.extra['account'], same(entry.account));
      expect(Accounts.main, same(replacement));
    }
  });

  test('签名准备异常在发送前返回明确失败，取消查询不发送目标请求', () async {
    await GStorage.localCache.put(LocalCacheKey.timeStamp, 'invalid');
    for (final invoke in [
      writes['发送弹幕']!,
      queries['播放地址']!,
      queries['弹幕凭据']!,
      queries['屏蔽规则']!,
      writes['点赞']!,
      queries['贡献榜']!,
    ]) {
      final result = await invoke() as Error;
      expect(result, isNot(isA<UnknownResult>()));
      expect(result.cause, isNotNull);
    }
    expect(requests, isEmpty);
    await GStorage.localCache.put(
      LocalCacheKey.timeStamp,
      DateTime.now().millisecondsSinceEpoch,
    );
    final token = CancelToken()..cancel('closed');
    final result =
        await LiveHttp.liveRoomInfo(roomId: 12, cancelToken: token) as Error;
    expect(result.toString(), '请求已取消');
    expect(requests, isEmpty);
  });

  test('屏蔽用户必须确认同一目标，删除仍允许空数据', () async {
    body = {
      'code': 0,
      'data': {'uid': 2, 'uname': 'two'},
    };
    final added = await LiveHttp.liveShieldUser(uid: 2, roomid: 12, type: 1);
    expect(added.data?.uid, 2);
    expect(
      await LiveHttp.liveShieldUser(uid: 3, roomid: 12, type: 1),
      isA<UnknownResult>(),
    );
    body = {'code': 0};
    expect(
      await LiveHttp.liveShieldUser(uid: 2, roomid: 12, type: 1),
      isA<UnknownResult>(),
    );
    expect(
      (await LiveHttp.liveShieldUser(uid: 2, roomid: 12, type: 0)).data,
      isNull,
    );
  });
}
