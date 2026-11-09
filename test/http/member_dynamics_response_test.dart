import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pili_aurora/http/api.dart';
import 'package:pili_aurora/http/init.dart';
import 'package:pili_aurora/http/loading_state.dart';
import 'package:pili_aurora/http/member.dart';
import 'package:pili_aurora/models/common/account_type.dart';
import 'package:pili_aurora/models/dynamics/result.dart';
import 'package:pili_aurora/utils/accounts.dart';
import 'package:pili_aurora/utils/accounts/account.dart';
import 'package:pili_aurora/utils/storage.dart';
import 'package:pili_aurora/utils/storage_key.dart';

import '../support/memory_box.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  LoginAccount account(int id) => LoginAccount(
    BiliCookieJar.fromJson({'DedeUserID': '$id', 'bili_jct': 'fixture-$id'}),
    null,
    null,
  );
  final original = account(1);
  final replacement = account(2);
  final requests = <RequestOptions>[];
  Object? body;
  Object? Function(RequestOptions)? respond;
  var failTransport = false;
  var switchWhileSigning = false;

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
    Accounts.accountMode[AccountType.main.index] = original;
    await GStorage.localCache.putAll({
      LocalCacheKey.mixinKey: 'synthetic',
      LocalCacheKey.timeStamp: DateTime.now().millisecondsSinceEpoch,
    });
    requests.clear();
    failTransport = switchWhileSigning = false;
    body = respond = null;
    DynamicsDataModel.enableFilter = false;
  });
  tearDownAll(() => Request.dio.close(force: true));

  test('空间动态查询保留解析和传输原因、明确拒绝码及成功列表', () async {
    for (final invalid in [
      null,
      [],
      {'code': '0'},
      {'code': 0},
    ]) {
      body = invalid;
      final result = await MemberHttp.memberDynamic(mid: 1) as Error;
      expect(result, isNot(isA<UnknownResult>()));
      expect(result.cause, isNotNull);
      expect(result.stackTrace, isNotNull);
    }
    body = {'code': -667777, 'message': '无访问权限'};
    final denied = await MemberHttp.memberDynamic(mid: 1) as Error;
    expect(denied.code, -667777);
    expect(denied.toString(), '无访问权限');
    failTransport = true;
    final failed = await MemberHttp.memberDynamic(mid: 1) as Error;
    expect(failed.cause, isA<DioException>());
    expect(failed.stackTrace, isNotNull);
    failTransport = false;
    body = {
      'code': 0,
      'data': {
        'has_more': false,
        'items': [
          {'id_str': '1'},
        ],
      },
    };
    expect(
      (await MemberHttp.memberDynamic(mid: 1)).data.items!.single.idStr,
      '1',
    );
  });

  test('空间动态签名期间切号仍使用发起账号和空间请求头', () async {
    await GStorage.localCache.clear();
    switchWhileSigning = true;
    body = {
      'code': 0,
      'data': {'has_more': false},
    };
    expect(await MemberHttp.memberDynamic(mid: 42), isA<Success>());
    expect(Accounts.main, same(replacement));
    final request = requests.last;
    expect(request.path, Api.memberDynamic);
    expect(request.extra['account'], same(original));
    expect(request.queryParameters['host_mid'], 42);
    expect(request.headers['referer'], 'https://space.bilibili.com/42/dynamic');
    expect(request.headers['origin'], 'https://space.bilibili.com');
  });

  test('空间动态过滤补页固定账号，拒绝无进展游标并限制请求数', () async {
    final previousPattern = DynamicsDataModel.banWordForDyn;
    final previousFilter = DynamicsDataModel.enableFilter;
    addTearDown(() {
      DynamicsDataModel.banWordForDyn = previousPattern;
      DynamicsDataModel.enableFilter = previousFilter;
    });
    DynamicsDataModel.enableFilter = true;
    DynamicsDataModel.banWordForDyn = RegExp('blocked');
    final filtered = {
      'id_str': '1',
      'modules': {
        'module_dynamic': {
          'desc': {'text': 'blocked'},
        },
      },
    };
    respond = (request) {
      Accounts.accountMode[AccountType.main.index] = replacement;
      final first = request.queryParameters['offset'] == '';
      return {
        'code': 0,
        'data': {
          'has_more': first,
          'offset': 'next',
          'items': [
            first ? filtered : {'id_str': '2'},
          ],
        },
      };
    };
    expect(
      (await MemberHttp.memberDynamic(mid: 1)).data.items!.single.idStr,
      '2',
    );
    expect(requests, hasLength(2));
    expect(
      requests.every((e) => identical(e.extra['account'], original)),
      isTrue,
    );
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
      expect(await MemberHttp.memberDynamic(mid: 1), isA<Error>());
      expect(requests.length, lessThanOrEqualTo(2));
    }
    requests.clear();
    respond = (_) => {
      'code': 0,
      'data': {
        'has_more': true,
        'offset': '${requests.length}',
        'items': [filtered],
      },
    };
    expect(await MemberHttp.memberDynamic(mid: 1), isA<Error>());
    expect(requests, hasLength(100));
  });
}
