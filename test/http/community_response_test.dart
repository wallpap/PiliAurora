import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pili_aurora/http/api.dart';
import 'package:pili_aurora/http/danmaku.dart';
import 'package:pili_aurora/http/init.dart';
import 'package:pili_aurora/http/loading_state.dart';
import 'package:pili_aurora/http/reply.dart';
import 'package:pili_aurora/models/common/account_type.dart';
import 'package:pili_aurora/utils/accounts.dart';
import 'package:pili_aurora/utils/accounts/account.dart';
import 'package:pili_aurora/utils/storage.dart';

import '../support/memory_box.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  Account account(int id) => LoginAccount(
    BiliCookieJar.fromJson({'DedeUserID': '$id', 'bili_jct': 'fixture-$id'}),
    null,
    null,
  );
  final main = account(1);
  final replacement = account(2);
  Object? body;
  var failTransport = false;
  var switchAccount = false;
  final requests = <RequestOptions>[];
  final pages = <Object?>[];
  final queries = <Future<LoadingState<dynamic>> Function()>[
    () => DanmakuHttp.likeStats(cid: 1, id: 2, account: main),
    for (final isLogin in [false, true]) ...[
      () => ReplyHttp.replyList(
        isLogin: isLogin,
        oid: 1,
        nextOffset: '',
        type: 1,
        page: 1,
      ),
      () => ReplyHttp.replyReplyList(
        isLogin: isLogin,
        oid: 1,
        root: 2,
        pageNum: 1,
        type: 1,
      ),
    ],
    ReplyHttp.getEmoteList,
    ReplyHttp.getEmoteSettingPanel,
    () => ReplyHttp.getMyEmotePackages(type: 0),
    () => ReplyHttp.getEmotePackageDetail(packageId: 1),
    () => ReplyHttp.replyInteraction(oid: 1, type: 1),
  ];
  final writes = <Future<LoadingState<dynamic>> Function()>[
    () => DanmakuHttp.shootDanmaku(oid: 1, bvid: 'BV1xx411c7mD', msg: 'test'),
    () => DanmakuHttp.danmakuLike(isLike: true, cid: 1, id: 2),
    () => DanmakuHttp.danmakuReport(reason: 1, cid: 1, id: 2),
    () => DanmakuHttp.danmakuRecall(cid: 1, id: 2),
    () => DanmakuHttp.danmakuEditState(oid: 1, ids: [2], state: 1),
    () => ReplyHttp.hateReply(type: 1, action: 1, oid: 1, rpid: 2),
    () => ReplyHttp.likeReply(type: 1, action: 1, oid: 1, rpid: 2),
    () => ReplyHttp.addEmotePackage(packageId: 1),
    () => ReplyHttp.removeEmotePackage(packageId: 1),
    () => ReplyHttp.replyTop(oid: 1, type: 1, rpid: 2, isUpTop: false),
    () => ReplyHttp.report(rpid: 2, oid: 1, reasonType: 1),
    () => ReplyHttp.replySubjectModify(oid: 1, type: 1, action: 1),
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
            if (failTransport) {
              handler.reject(
                DioException(
                  requestOptions: options,
                  type: DioExceptionType.receiveTimeout,
                ),
              );
              return;
            }
            if (switchAccount) {
              Accounts.accountMode[AccountType.main.index] = replacement;
            }
            handler.resolve(
              Response(
                requestOptions: options,
                data: pages.isEmpty
                    ? body
                    : pages[(options.queryParameters['pn'] as int) - 1],
              ),
            );
          },
        ),
      );
  });
  setUp(() {
    Accounts.accountMode[AccountType.main.index] = main;
    requests.clear();
    pages.clear();
    body = null;
    failTransport = switchAccount = false;
  });
  tearDownAll(() => Request.dio.close(force: true));

  test('弹幕和评论查询的损坏响应通过结果返回并保留原因', () async {
    for (final invalid in [
      null,
      [],
      {'code': '0'},
      {'code': 0, 'data': 'private body'},
    ]) {
      body = invalid;
      for (final invoke in queries) {
        final result = await invoke() as Error;
        expect(result.cause, isNotNull);
        expect(result.stackTrace, isNotNull);
        expect(result.toString(), isNot(contains('private body')));
      }
    }
  });

  test('明确拒绝保留业务码，评论可见性检查无需解析提示文本', () async {
    body = {'code': 12022, 'msg': '评论不可见'};
    for (final invoke in [...queries, ...writes]) {
      final result = await invoke() as Error;
      expect(result, isNot(isA<UnknownResult>()));
      expect(result.code, 12022);
      expect(result.toString(), '评论不可见');
    }
  });

  test('写入允许可选数据缺失，损坏和断连保持待确认并绑定账号', () async {
    for (final invoke in writes) {
      body = {'code': 0, 'data': <String, dynamic>{}};
      expect(await invoke(), isA<Success>());
      body = {'code': '0'};
      expect(await invoke(), isA<UnknownResult>());
      failTransport = true;
      final result = await invoke() as UnknownResult;
      expect(result.cause, isA<DioException>());
      expect(requests.last.extra['noRetry'], isTrue);
      expect(requests.last.extra['account'], same(main));
      expect((requests.last.data as Map)['csrf'], main.csrf);
      failTransport = false;
    }
  });

  test('匿名评论查询保留空 Cookie 和 NoAccount，不带 CSRF', () async {
    body = {'code': 0, 'data': <String, dynamic>{}};
    expect(await queries[1](), isA<Success>());
    expect(requests.last.path, '${Api.replyList}/main');
    expect(await queries[2](), isA<Success>());
    for (final request in requests) {
      expect(request.extra['account'], isA<NoAccount>());
      expect(request.headers['cookie'], '');
      expect(request.queryParameters.containsKey('csrf'), isFalse);
    }
  });

  test('弹幕点赞状态要求数值，发送可缺少 dmid，管理使用正确端点', () async {
    body = {
      'code': 0,
      'data': {
        '2': {'likes': 3, 'user_like': 1},
      },
    };
    expect((await DanmakuHttp.likeStats(cid: 1, id: 2, account: main)).data, (
      likes: 3,
      isLike: true,
    ));
    body = {
      'code': 0,
      'data': {
        '2': {'likes': 3},
      },
    };
    expect(
      await DanmakuHttp.likeStats(cid: 1, id: 2, account: main),
      isA<Error>(),
    );
    body = {'code': 0, 'data': <String, dynamic>{}};
    expect(
      (await DanmakuHttp.shootDanmaku(
        oid: 1,
        bvid: 'test',
        msg: 'test',
      )).data.dmid,
      isNull,
    );
    await DanmakuHttp.danmakuEditState(oid: 1, ids: [2, 3], state: 1);
    expect(requests.last.path, Api.danmakuEditState);
    expect((requests.last.data as Map)['dmids'], '2,3');
  });

  Object page(int total, List<int> ids) => {
    'code': 0,
    'data': {
      'total': total,
      'packages': [
        for (final id in ids) {'id': id},
      ],
    },
  };

  test('表情包分页固定发起账号，去重后继续读取完整列表', () async {
    pages.addAll([
      page(3, [1, 2]),
      page(3, [2, 3]),
    ]);
    switchAccount = true;
    final result = await ReplyHttp.getMyEmotePackages(type: 0);
    expect(result.data.map((item) => item.id), [1, 2, 3]);
    expect(requests, hasLength(2));
    expect(
      requests.every((request) => identical(request.extra['account'], main)),
      isTrue,
    );
  });

  test('重复页、提前结束和中途失败不交付成功的残缺表情包列表', () async {
    for (final last in [
      page(3, [1]),
      page(3, []),
      {'code': -403, 'message': '加载被拒绝'},
    ]) {
      pages
        ..clear()
        ..addAll([
          page(3, [1]),
          last,
        ]);
      final start = requests.length;
      final result = await ReplyHttp.getMyEmotePackages(type: 0);
      expect(result, isA<Error>());
      expect(requests.length - start, 2);
    }
    expect((await ReplyHttp.getMyEmotePackages(type: 0) as Error).code, -403);
  });

  test('表情包总数和详情归属必须有效，可选空列表和操作文案可保留', () async {
    for (final total in [null, '2', -1]) {
      body = {
        'code': 0,
        'data': {'total': total, 'packages': []},
      };
      expect(
        (await ReplyHttp.getMyEmotePackages(type: 0) as Error).cause,
        isNotNull,
      );
    }
    body = page(0, []);
    expect((await ReplyHttp.getMyEmotePackages(type: 0)).data, isEmpty);
    body = {
      'code': 0,
      'data': {
        'package': {'id': 2},
      },
    };
    expect(await ReplyHttp.getEmotePackageDetail(packageId: 1), isA<Error>());
    body = {'code': 0, 'data': <String, dynamic>{}};
    expect((await ReplyHttp.getEmoteList()).data, isNull);
    expect((await ReplyHttp.getEmoteSettingPanel()).data.allPackages, isEmpty);
    expect(
      (await ReplyHttp.replySubjectModify(oid: 1, type: 1, action: 1)).data,
      isNull,
    );
    body = {
      'code': 0,
      'data': {'action_toast': '设置已保存'},
    };
    expect(
      (await ReplyHttp.replySubjectModify(oid: 1, type: 1, action: 1)).data,
      '设置已保存',
    );
    body = {
      'code': 0,
      'data': {'all_packages': 'invalid'},
    };
    expect(await ReplyHttp.getEmoteSettingPanel(), isA<Error>());
  });
}
