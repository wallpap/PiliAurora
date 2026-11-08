import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:pili_aurora/http/init.dart';
import 'package:pili_aurora/models/common/account_type.dart';
import 'package:pili_aurora/models/user/info.dart';
import 'package:pili_aurora/pages/mine/controller.dart';
import 'package:pili_aurora/services/account_service.dart';
import 'package:pili_aurora/utils/accounts.dart';
import 'package:pili_aurora/utils/accounts/account.dart';
import 'package:pili_aurora/utils/global_data.dart';
import 'package:pili_aurora/utils/login_utils.dart';
import 'package:pili_aurora/utils/storage.dart';

import '../support/controlled_http_adapter.dart';
import '../support/memory_box.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final adapter = ControlledHttpAdapter();
  final dispatched = adapter.waitForRequests;
  final profile = MemoryBox<UserInfoData>();
  late Account previousAccount;
  late Account first;
  final mainIndex = AccountType.main.index;

  Map<String, Object?> info({int money = 10}) => {
    'code': 0,
    'data': {
      'isLogin': true,
      'face': 'fixture-face',
      'money': money,
      'mid': 123,
    },
  };
  Account account(int mid) => LoginAccount(
    BiliCookieJar.fromJson({'DedeUserID': '$mid', 'bili_jct': 'fixture'}),
    null,
    null,
  );

  setUpAll(() {
    GStorage.setting = MemoryBox<dynamic>();
    GStorage.localCache = MemoryBox<dynamic>();
    GStorage.userInfo = profile;
    Request();
    Request.dio.interceptors.clear();
    Request.dio.httpClientAdapter = adapter;
    Get.testMode = true;
  });
  setUp(() {
    previousAccount = Accounts.main;
    first = account(123);
    Accounts.accountMode[mainIndex] = first;
    profile.data.clear();
    adapter.requests.clear();
    adapter.pending.clear();
    GlobalData().coins = 30;
    Get.put(AccountService());
  });
  tearDown(() {
    Accounts.accountMode[mainIndex] = previousAccount;
    Get.reset();
  });
  tearDownAll(() => Request.dio.close(force: true));

  test('硬币请求绑定发起账号，切号后迟到结果不写入共享余额', () async {
    final pending = Request.setCoin();
    await dispatched(1);
    expect(adapter.requests.single.extra['account'], same(first));
    Accounts.accountMode[mainIndex] = account(456);
    adapter.json(0, {
      'code': 0,
      'data': {'money': 99},
    });
    await pending;
    expect(GlobalData().coins, 30);
    final current = Request.setCoin();
    await dispatched(2);
    adapter.json(1, {
      'code': 0,
      'data': {'money': 12},
    });
    await current;
    expect(GlobalData().coins, 12);
  });

  test('登录查询在切号后不再同步旧头像、Cookie、缓存或余额', () async {
    final pending = LoginUtils.onLoginMain();
    await dispatched(1);
    expect(adapter.requests.single.extra['account'], same(first));
    Accounts.accountMode[mainIndex] = account(456);
    adapter.json(0, info());
    await pending;
    expect(Get.find<AccountService>().isLogin.value, isFalse);
    expect(profile.data, isEmpty);
    expect(GlobalData().coins, 30);
  });

  test('个人页忽略切号或释放后的资料结果', () async {
    for (final close in [false, true]) {
      adapter.requests.clear();
      adapter.pending.clear();
      final controller = MineController();
      final pending = controller.queryUserInfo();
      await dispatched(1);
      if (close) {
        controller.onDelete();
      } else {
        Accounts.accountMode[mainIndex] = account(456);
      }
      adapter.json(0, info());
      await pending;
      expect(controller.userInfo.value.mid, isNull);
      expect(profile.data, isEmpty);
      expect(GlobalData().coins, 30);
      expect(adapter.requests, hasLength(1));
      if (!close) controller.onDelete();
      Accounts.accountMode[mainIndex] = first;
    }
  });

  test('个人页同账号最新查询优先，旧未登录响应不能触发登出', () async {
    final controller = MineController();
    addTearDown(controller.onDelete.call);
    final old = controller.queryUserInfo();
    final latest = controller.queryUserInfo();
    await dispatched(2);
    adapter.json(1, info(money: 12));
    await latest;
    await dispatched(3);
    adapter.json(2, {
      'code': 0,
      'data': {'follower': 7},
    });
    await Future<void>.delayed(Duration.zero);
    adapter.json(0, {'code': -101, 'message': '账号未登录'});
    await old;
    expect(Accounts.main, same(first));
    expect(controller.userInfo.value.money, 12);
    expect(controller.userStat.value.follower, 7);
    expect(profile.data['userInfoCache']!.mid, 123);
    expect(GlobalData().coins, 12);
  });
}
