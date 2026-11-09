import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pili_aurora/http/api.dart';
import 'package:pili_aurora/http/dynamics.dart';
import 'package:pili_aurora/http/init.dart';
import 'package:pili_aurora/http/loading_state.dart';
import 'package:pili_aurora/models/dynamics/vote_model.dart';
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
  final heartbeat = account(2);
  final recommend = account(3);
  final replacement = account(4);
  final requests = <RequestOptions>[];
  Object? body;
  Object? Function(RequestOptions)? respond;
  var failTransport = false;
  var switchWhileSigning = false;
  final queries = <Future<LoadingState<dynamic>> Function()>[
    DynamicsHttp.followDynamic,
    DynamicsHttp.followUp,
    () => DynamicsHttp.dynUpList(null),
    () => DynamicsHttp.followings(vmid: 1, pn: 1),
    () => DynamicsHttp.dynamicDetail(id: '1'),
    () => DynamicsHttp.articleInfo(cvId: 1),
    () => DynamicsHttp.articleView(cvId: 1),
    () => DynamicsHttp.opusDetail(opusId: '1'),
    () => DynamicsHttp.voteInfo(1),
    () => DynamicsHttp.topicTop(topicId: 1),
    () => DynamicsHttp.topicFeed(topicId: 1, sortBy: 0),
    () => DynamicsHttp.topicFold(topicId: 1, sortBy: 0),
    () => DynamicsHttp.articleList(id: 1, account: main),
    DynamicsHttp.dynTopicRcmd,
    () => DynamicsHttp.dynPic('1'),
    DynamicsHttp.dynMention,
    () => DynamicsHttp.reserveInfo(sid: 1),
    () => DynamicsHttp.followeeVotes(voteId: 1),
    () => DynamicsHttp.bubble(tribeId: 1, page: 1),
    () => DynamicsHttp.dynReaction(id: '1'),
  ];
  final writes = <Future<LoadingState<dynamic>> Function()>[
    () => DynamicsHttp.thumbDynamic(dynamicId: '1', up: 1),
    () => DynamicsHttp.createDynamic(rawText: 'test'),
    () => DynamicsHttp.setTop(dynamicId: '1'),
    () => DynamicsHttp.rmTop(dynamicId: '1'),
    () => DynamicsHttp.doVote(voteId: 1, votes: [1]),
    () => DynamicsHttp.dynReserve(
      reserveId: 1,
      curBtnStatus: 0,
      dynamicIdStr: '1',
      reserveTotal: 0,
    ),
    () => DynamicsHttp.createVote(VoteInfo(title: 'test')),
    () => DynamicsHttp.updateVote(VoteInfo(title: 'test', voteId: 1)),
    () => DynamicsHttp.createReserve(title: 'test', livePlanStartTime: 1),
    () =>
        DynamicsHttp.updateReserve(sid: 1, title: 'test', livePlanStartTime: 1),
    () => DynamicsHttp.dynPrivatePubSetting(dynId: '1', action: 'set'),
    () => DynamicsHttp.editDyn(dynId: '1', rawText: 'test'),
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
              handler.resolve(
                Response(
                  requestOptions: options,
                  data: respond == null ? body : respond!(options),
                ),
              );
            }
          },
        ),
      );
  });
  setUp(() async {
    Accounts.accountMode[AccountType.main.index] = main;
    Accounts.accountMode[AccountType.heartbeat.index] = heartbeat;
    Accounts.accountMode[AccountType.recommend.index] = recommend;
    await GStorage.localCache.putAll({
      LocalCacheKey.mixinKey: 'synthetic',
      LocalCacheKey.timeStamp: DateTime.now().millisecondsSinceEpoch,
    });
    requests.clear();
    failTransport = switchWhileSigning = false;
    body = respond = null;
  });
  tearDownAll(() => Request.dio.close(force: true));

  test('动态查询的损坏响应沿结果交付并保留原始原因', () async {
    for (final invalid in [
      null,
      [],
      {'code': '0'},
      {'code': 0, 'data': 'private body'},
    ]) {
      body = invalid;
      for (final query in queries) {
        final result = await query() as Error;
        expect(result.cause, isNotNull);
        expect(result.stackTrace, isNotNull);
        expect(result.toString(), isNot(contains('private body')));
      }
    }
  });

  test('动态所有接口保留明确拒绝码和业务文案', () async {
    body = {'code': -667777, 'msg': '操作被拒绝'};
    for (final invoke in [...queries, ...writes]) {
      final result = await invoke() as Error;
      expect(result, isNot(isA<UnknownResult>()));
      expect(result.code, -667777);
      expect(result.toString(), '操作被拒绝');
    }
    body = {'code': 4101132};
    final empty = await DynamicsHttp.followDynamic() as Error;
    expect(empty.code, 4101132);
    expect(empty.toString(), '没有数据');
  });

  test('动态写入断连和损坏协议待确认，账号与 CSRF 固定且禁止重试', () async {
    for (final write in writes) {
      body = {'code': '0'};
      expect(await write(), isA<UnknownResult>());
      failTransport = true;
      expect(await write(), isA<UnknownResult>());
      final request = requests.last;
      expect(request.extra['noRetry'], isTrue);
      expect(request.extra['account'], same(main));
      final params = {...request.queryParameters, ...?request.data as Map?};
      expect(params['csrf'], main.csrf);
      failTransport = false;
    }
  });

  test('动态可选内容和定时发布允许空结果，发布 ID 采用明确的可空字符串', () async {
    body = {'code': 0};
    expect((await DynamicsHttp.createDynamic(publishTime: 1)).data, isNull);
    for (final query in [
      () => DynamicsHttp.topicTop(topicId: 1),
      () => DynamicsHttp.topicFeed(topicId: 1, sortBy: 0),
      () => DynamicsHttp.topicFold(topicId: 1, sortBy: 0),
      DynamicsHttp.dynTopicRcmd,
      () => DynamicsHttp.dynPic('1'),
      () => DynamicsHttp.followeeVotes(voteId: 1),
    ]) {
      expect((await query()).data, isNull);
    }
    for (final id in [123, '123']) {
      body = {
        'code': 0,
        'data': {'dyn_id': id},
      };
      expect((await DynamicsHttp.createDynamic(rawText: 'test')).data, '123');
    }
    body = {
      'code': 0,
      'data': {'dyn_id': 'invalid'},
    };
    expect(
      await DynamicsHttp.createDynamic(rawText: 'test'),
      isA<UnknownResult>(),
    );
    body = {'code': 0};
    for (final write in [
      writes[0],
      writes[2],
      writes[3],
      writes[10],
      writes[11],
    ]) {
      expect(await write(), isA<Success>());
    }
  });

  test('投票和预约创建必须有有效 ID，编辑空回执可沿用已知 ID', () async {
    for (final id in [null, 0, -1, 'invalid']) {
      body = {
        'code': 0,
        'data': {'vote_id': id, 'sid': id},
      };
      expect(await writes[6](), isA<UnknownResult>());
      expect(await writes[8](), isA<UnknownResult>());
    }
    body = {'code': 0};
    expect((await writes[7]()).data, 1);
    expect((await writes[9]()).data, 1);
    body = {
      'code': 0,
      'data': {'vote_id': 2, 'sid': 2},
    };
    expect(await writes[7](), isA<UnknownResult>());
    expect(await writes[9](), isA<UnknownResult>());
    expect((await writes[6]()).data, 2);
    expect((await writes[8]()).data, 2);
  });

  test('投票与预约编辑查询拒绝缺少必需字段的详情', () async {
    body = {
      'code': 0,
      'data': {
        'vote_info': {'vote_id': 1},
      },
    };
    expect(
      (await DynamicsHttp.voteInfo(1) as Error).cause,
      isA<FormatException>(),
    );
    body = {
      'code': 0,
      'data': {'id': 1},
    };
    expect(
      (await DynamicsHttp.reserveInfo(sid: 1) as Error).cause,
      isA<FormatException>(),
    );
    body = {
      'code': 0,
      'data': {'id': 1, 'title': '预约', 'live_plan_start_time': 1},
    };
    expect(await DynamicsHttp.reserveInfo(sid: 1), isA<Success>());
    expect(await DynamicsHttp.reserveInfo(sid: 2), isA<Error>());
    body = {'code': 0, 'data': <String, dynamic>{}};
    expect(await writes[5](), isA<UnknownResult>());
  });

  test('动态详情保留播放记录角色，话题推荐保留推荐角色，匿名不带 CSRF', () async {
    body = {
      'code': 0,
      'data': {
        'item': {'id_str': '1'},
      },
    };
    expect(await DynamicsHttp.dynamicDetail(id: '1'), isA<Success>());
    expect(requests.last.extra['account'], same(heartbeat));
    expect(requests.last.queryParameters['csrf'], heartbeat.csrf);
    await DynamicsHttp.dynamicDetail(id: '1', clearCookie: true);
    expect(requests.last.extra['account'], isA<NoAccount>());
    expect(requests.last.headers['cookie'], '');
    expect(requests.last.queryParameters.containsKey('csrf'), isFalse);
    body = {'code': 0};
    await DynamicsHttp.topicTop(topicId: 1);
    expect(requests.last.extra['account'], same(recommend));
    await DynamicsHttp.topicFeed(topicId: 1, sortBy: 0);
    expect(requests.last.extra['account'], same(recommend));
    await DynamicsHttp.dynTopicRcmd();
    expect(requests.last.extra['account'], same(recommend));
  });

  test('动态过滤补页绑定同一账号并拒绝重复或缺失游标', () async {
    final filtered = {
      'id_str': '1',
      'modules': {
        'module_author': {'mid': 99},
      },
    };
    respond = (request) {
      Accounts.accountMode[AccountType.main.index] = replacement;
      return {
        'code': 0,
        'data': {
          'has_more': request.queryParameters['offset'] == null,
          'offset': 'next',
          'items': [
            request.queryParameters['offset'] == null
                ? filtered
                : {'id_str': '2'},
          ],
        },
      };
    };
    final result = await DynamicsHttp.followDynamic(tempBannedList: {99});
    expect(result.data.items!.single.idStr, '2');
    expect(requests, hasLength(2));
    expect(requests.every((e) => identical(e.extra['account'], main)), isTrue);
    for (final cursor in [null, '', 'next']) {
      requests.clear();
      respond = (_) => {
        'code': 0,
        'data': {
          'has_more': true,
          'offset': cursor,
          'items': [filtered],
        },
      };
      expect(
        await DynamicsHttp.followDynamic(tempBannedList: {99}),
        isA<Error>(),
      );
      expect(requests.length, lessThanOrEqualTo(2));
    }
  });

  test('签名期间切号不改变图文查询和动态编辑的发起账号', () async {
    for (final invoke in [queries[5], queries[6], queries[7], writes[11]]) {
      Accounts.accountMode[AccountType.main.index] = main;
      await GStorage.localCache.clear();
      switchWhileSigning = true;
      body = {'code': -667777, 'message': '拒绝'};
      await invoke();
      expect(requests.last.extra['account'], same(main));
      if (requests.last.method == 'POST') {
        expect(requests.last.queryParameters['csrf'], main.csrf);
      }
      expect(Accounts.main, same(replacement));
    }
  });

  test('动态补充：完整投票结果可查询与提交，错误目标不能误更新', () async {
    final info = {
      'vote_id': 1,
      'title': '投票',
      'end_time': 1,
      'choice_cnt': 1,
      'options': [
        {'opt_idx': 1, 'opt_desc': '甲', 'cnt': 2},
        {'opt_idx': 2, 'opt_desc': '乙', 'cnt': 1},
      ],
    };
    body = {
      'code': 0,
      'data': {
        'vote_info': info,
        'my_votes': [1],
      },
    };
    expect((await DynamicsHttp.voteInfo(1)).data.myVotes, [1]);
    expect(
      (await DynamicsHttp.doVote(voteId: 1, votes: [1])).data.options,
      hasLength(2),
    );
    expect(
      await DynamicsHttp.doVote(voteId: 2, votes: [1]),
      isA<UnknownResult>(),
    );
  });

  test('动态补充：过滤分页即使游标持续变化也有请求上限', () async {
    respond = (_) => {
      'code': 0,
      'data': {
        'has_more': true,
        'offset': '${requests.length}',
        'items': [
          {
            'id_str': '1',
            'modules': {
              'module_author': {'mid': 99},
            },
          },
        ],
      },
    };
    expect(
      await DynamicsHttp.followDynamic(tempBannedList: {99}),
      isA<Error>(),
    );
    expect(requests, hasLength(100));
  });
}
