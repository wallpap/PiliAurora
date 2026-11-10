import 'package:flutter_test/flutter_test.dart';
import 'package:pili_aurora/http/init.dart';
import 'package:pili_aurora/http/loading_state.dart';
import 'package:pili_aurora/models/common/account_type.dart';
import 'package:pili_aurora/models/remote/popular/popular_series_one/data.dart';
import 'package:pili_aurora/pages/popular_series/controller.dart';
import 'package:pili_aurora/utils/accounts.dart';
import 'package:pili_aurora/utils/accounts/account.dart';
import 'package:pili_aurora/utils/storage.dart';
import 'package:pili_aurora/utils/storage_key.dart';

import '../../support/controlled_interceptor.dart';
import '../../support/memory_box.dart';

class _Controller extends PopularSeriesController {
  int queries = 0;
  @override
  Future<void>? prepareQuery() => null;
  @override
  Future<void>? prepareResponse(
    PopularSeriesOneData response,
    bool Function() isCurrent,
  ) => null;
  @override
  Future<LoadingState<PopularSeriesOneData>> customGetData() async {
    queries++;
    return Success(PopularSeriesOneData());
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final interceptor = ControlledInterceptor();
  final requests = interceptor.requests;
  late _Controller controller;
  setUpAll(() {
    GStorage.setting = MemoryBox();
    GStorage.video = MemoryBox();
    GStorage.localCache = MemoryBox();
    Request();
    Request.dio.interceptors
      ..clear()
      ..add(interceptor);
  });
  setUp(() async {
    requests.clear();
    controller = _Controller();
    Accounts.accountMode[AccountType.recommend.index] = AnonymousAccount();
    await GStorage.localCache.putAll({
      LocalCacheKey.timeStamp: DateTime.now().millisecondsSinceEpoch,
      LocalCacheKey.mixinKey: 'fixture-key',
    });
  });
  tearDown(() => controller.onDelete());
  tearDownAll(() async {
    Request.dio.close(force: true);
    await interceptor.close();
  });
  test('首次期数解析失败可重试，成功时等待实际列表加载', () async {
    var reading = controller.onReload();
    await interceptor.waitForRequests(1);
    requests[0].reply.complete({
      'code': 0,
      'data': {
        'list': [<String, dynamic>{}],
      },
    });
    await reading;
    expect(controller.loadingState.value, isA<Error>());
    expect(controller.queries, 0);
    reading = controller.onReload();
    await interceptor.waitForRequests(2);
    requests[1].reply.complete({
      'code': 0,
      'data': {
        'list': [
          {'number': 2},
        ],
      },
    });
    await reading;
    expect(controller.number, 2);
    expect(controller.queries, 1);
    expect(controller.loadingState.value.isSuccess, isTrue);
  });
  test('期数查询乱序只应用新请求，账号变更后不启动旧账号列表', () async {
    final first = controller.onReload();
    await interceptor.waitForRequests(1);
    final second = controller.onReload();
    await interceptor.waitForRequests(2);
    requests[1].reply.complete({
      'code': 0,
      'data': {
        'list': [
          {'number': 2},
        ],
      },
    });
    await second;
    requests[0].reply.complete({
      'code': 0,
      'data': {
        'list': [
          {'number': 1},
        ],
      },
    });
    await first;
    expect(controller.number, 2);
    expect(controller.queries, 1);
    controller.seriesList = null;
    final reading = controller.onReload();
    await interceptor.waitForRequests(3);
    Accounts.accountMode[AccountType.recommend.index] = LoginAccount(
      BiliCookieJar.fromJson({'DedeUserID': '1'}),
      null,
      null,
    );
    requests[2].reply.complete({
      'code': 0,
      'data': {
        'list': [
          {'number': 3},
        ],
      },
    });
    await reading;
    expect(controller.number, 2);
    expect(controller.queries, 1);
  });
  test('关闭页面后不消费迟到期数，也不继续加载列表', () async {
    final reading = controller.onReload();
    await interceptor.waitForRequests(1);
    controller.onDelete();
    requests[0].reply.complete({
      'code': 0,
      'data': {
        'list': [
          {'number': 1},
        ],
      },
    });
    await reading;
    expect(controller.seriesList, isNull);
    expect(controller.queries, 0);
  });
}
