import 'package:flutter_test/flutter_test.dart';
import 'package:pili_aurora/http/init.dart';
import 'package:pili_aurora/http/loading_state.dart';
import 'package:pili_aurora/models/common/account_type.dart';
import 'package:pili_aurora/pages/common/discovery_list_controller.dart';
import 'package:pili_aurora/pages/hot/controller.dart';
import 'package:pili_aurora/pages/popular_precious/controller.dart';
import 'package:pili_aurora/pages/popular_series/controller.dart';
import 'package:pili_aurora/pages/rank/zone/controller.dart';
import 'package:pili_aurora/utils/accounts.dart';
import 'package:pili_aurora/utils/accounts/account.dart';
import 'package:pili_aurora/utils/storage.dart';
import 'package:pili_aurora/utils/storage_key.dart';

import '../../support/controlled_interceptor.dart';
import '../../support/memory_box.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final interceptor = ControlledInterceptor();
  final requests = interceptor.requests;
  LoginAccount account() => LoginAccount(
    BiliCookieJar.fromJson({'DedeUserID': '1', 'bili_jct': 'fixture'}),
    null,
    null,
  );
  setUpAll(() {
    GStorage.setting = MemoryBox({SettingBoxKey.filterBlockedAuthors: false});
    GStorage.video = MemoryBox();
    GStorage.localCache = MemoryBox({
      LocalCacheKey.timeStamp: DateTime.now().millisecondsSinceEpoch,
      LocalCacheKey.mixinKey: 'fixture',
    });
    Request();
    Request.dio.interceptors
      ..clear()
      ..add(interceptor);
  });
  setUp(() {
    requests.clear();
    Accounts.accountMode[AccountType.main.index] = AnonymousAccount();
    Accounts.accountMode[AccountType.recommend.index] = account();
  });
  tearDownAll(() async {
    Request.dio.close(force: true);
    await interceptor.close();
  });
  final cases = <String, DiscoveryListController Function()>{
    '热门': HotController.new,
    '入站必刷': PopularPreciousController.new,
    '每周必看': () => PopularSeriesController()..number = 1,
    '分区排行榜': () => ZoneController(rid: 1),
    '番剧排行榜': () => ZoneController(seasonType: 1),
    '剧集排行榜': () => ZoneController(seasonType: 2),
  };
  for (final entry in cases.entries) {
    test('${entry.key}固定推荐请求账号，换凭据后丢弃旧响应并能刷新', () async {
      final controller = entry.value();
      addTearDown(controller.onDelete.call);
      final before = Accounts.get(AccountType.recommend);
      final operation = controller.onRefresh();
      await interceptor.waitForRequests(1);
      expect(requests[0].options.extra['account'], same(before));
      final replacement = account();
      Accounts.accountMode[AccountType.recommend.index] = replacement;
      const body = {
        'code': 0,
        'data': {'list': []},
        'result': {'list': []},
      };
      requests[0].reply.complete(body);
      await operation;
      expect(controller.loadingState.value, isA<Loading>());
      final retry = controller.onRefresh();
      await interceptor.waitForRequests(2);
      expect(requests[1].options.extra['account'], same(replacement));
      requests[1].reply.complete(body);
      await retry;
      expect(controller.loadingState.value, isA<Success>());
    });
  }
}
