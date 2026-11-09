import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pili_aurora/grpc/bilibili/main/community/reply/v1.pb.dart'
    show ReplyInfo;
import 'package:pili_aurora/http/init.dart';
import 'package:pili_aurora/http/loading_state.dart';
import 'package:pili_aurora/http/retry_interceptor.dart';
import 'package:pili_aurora/http/video.dart';
import 'package:pili_aurora/models/common/account_type.dart';
import 'package:pili_aurora/utils/accounts.dart';
import 'package:pili_aurora/utils/accounts/account.dart';
import 'package:pili_aurora/utils/storage.dart';

import '../support/memory_box.dart';

class _ReplyCache extends MemoryBox<Uint8List> {
  bool fail = false;

  @override
  Future<void> put(dynamic key, Uint8List value) async {
    if (fail) throw StateError('fixture cache');
    await super.put(key, value);
  }

  @override
  Future<void> delete(dynamic key) async {
    if (fail) throw StateError('fixture cache');
    await super.delete(key);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final account = LoginAccount(
    BiliCookieJar.fromJson({'DedeUserID': '1', 'bili_jct': 'fixture-csrf'}),
    null,
    null,
  );
  final cache = _ReplyCache();
  final requests = <RequestOptions>[];
  Object? body;
  var timeout = false;
  Future<LoadingState<ReplyInfo?>> add() =>
      VideoHttp.replyAdd(account: account, type: 1, oid: 1, message: '内容');
  Future<LoadingState<void>> delete() =>
      VideoHttp.replyDel(account: account, type: 1, oid: 1, rpid: 2);
  Map<String, dynamic> echo() => {
    'rpid': 2,
    'oid': 1,
    'type': 1,
    'root': 0,
    'parent': 0,
    'content': <String, dynamic>{'message': '内容'},
    'member': {
      'mid': 1,
      'uname': '作者',
      'avatar': '',
      'level_info': {'current_level': 6},
      'vip': {'vipStatus': 0, 'vipType': 0},
      'official_verify': {'type': -1},
    },
  };

  setUpAll(() {
    GStorage.setting = MemoryBox();
    GStorage.video = MemoryBox();
    GStorage.localCache = MemoryBox();
    GStorage.reply = cache;
    Request();
    Request.dio.interceptors
      ..clear()
      ..add(RetryInterceptor(Request.dio, 2, 0))
      ..add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            requests.add(options);
            if (timeout) {
              handler.reject(
                DioException(
                  requestOptions: options,
                  type: DioExceptionType.receiveTimeout,
                ),
                true,
              );
            } else {
              handler.resolve(Response(requestOptions: options, data: body));
            }
          },
        ),
      );
  });
  setUp(() {
    Accounts.accountMode[AccountType.main.index] = AnonymousAccount();
    requests.clear();
    cache
      ..fail = false
      ..data.clear();
    timeout = false;
  });
  tearDownAll(() => Request.dio.close(force: true));

  test('评论写入区分拒绝与待确认，固定账号和 CSRF 且不重试', () async {
    for (final invoke in [add, delete]) {
      body = {'code': 12022, 'message': '评论不可操作'};
      final rejected = await invoke() as Error;
      expect(rejected, isNot(isA<UnknownResult>()));
      expect(rejected.code, 12022);
      expect(rejected.toString(), '评论不可操作');
      body = {'code': '0'};
      expect(await invoke(), isA<UnknownResult>());
      requests.clear();
      timeout = true;
      final unknown = await invoke() as UnknownResult;
      expect(unknown.cause, isA<DioException>());
      expect(requests, hasLength(1));
      expect(requests.single.extra['account'], same(account));
      expect(requests.single.extra['noRetry'], isTrue);
      expect((requests.single.data as Map)['csrf'], account.csrf);
      timeout = false;
    }
  });

  test('明确发送成功时，缺失或损坏回显交付成功并等待列表重查', () async {
    for (final data in [
      null,
      <String, dynamic>{},
      {'reply': <String, dynamic>{}},
      {'reply': echo()..['oid'] = 9},
      {'reply': echo()..['rpid'] = 0},
    ]) {
      body = {'code': 0, 'data': data};
      final result = await add();
      expect(result, isA<Success>());
      expect(result.dataOrNull, isNull);
      expect(cache.data, isEmpty);
    }
  });

  test('有效回显保存到本地，缓存写入和清理失败均保留远端成功', () async {
    body = {
      'code': 0,
      'data': {'reply': echo()},
    };
    final added = await add();
    expect(added.dataOrNull!.id.toInt(), 2);
    expect(cache.data['2'], isNotEmpty);
    cache.fail = true;
    body = {
      'code': 0,
      'data': {'reply': echo()},
    };
    expect((await add()).dataOrNull!.id.toInt(), 2);
    body = {'code': 0};
    expect(await delete(), isA<Success>());
    expect(cache.data['2'], isNotEmpty);
    cache.fail = false;
    expect(await delete(), isA<Success>());
    expect(cache.data, isEmpty);
  });
}
