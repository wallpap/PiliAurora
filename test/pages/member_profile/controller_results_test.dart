import 'package:flutter_test/flutter_test.dart';
import 'package:pili_aurora/http/init.dart';
import 'package:pili_aurora/http/loading_state.dart';
import 'package:pili_aurora/models/common/account_type.dart';
import 'package:pili_aurora/models/common/member/profile_type.dart';
import 'package:pili_aurora/models/remote/account_myinfo/data.dart';
import 'package:pili_aurora/models/user/info.dart';
import 'package:pili_aurora/pages/member_profile/controller.dart';
import 'package:pili_aurora/utils/accounts.dart';
import 'package:pili_aurora/utils/accounts/account.dart';
import 'package:pili_aurora/utils/storage.dart';

import '../../support/controlled_interceptor.dart';
import '../../support/memory_box.dart';

class _Cache extends MemoryBox<UserInfoData> {
  bool fail = false;
  @override
  Future<void> put(dynamic key, UserInfoData value) async {
    if (fail) throw StateError('synthetic private-cache');
    await super.put(key, value);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final interceptor = ControlledInterceptor();
  final cache = _Cache();
  final requests = interceptor.requests;
  late MemberProfileController controller;
  LoginAccount login(String key) => LoginAccount(
    BiliCookieJar.fromJson({'DedeUserID': '1', 'bili_jct': key}),
    key,
    null,
  );
  Object info(String name) => {
    'code': 0,
    'data': {'mid': 1, 'name': name, 'coins': 10},
  };
  setUpAll(() {
    GStorage.setting = MemoryBox();
    GStorage.video = MemoryBox();
    GStorage.localCache = MemoryBox();
    GStorage.userInfo = cache;
    Request();
    Request.dio.interceptors
      ..clear()
      ..add(interceptor);
  });
  setUp(() async {
    requests.clear();
    cache.fail = false;
    await cache.clear();
    Accounts.accountMode[AccountType.main.index] = login('old');
    controller = MemberProfileController()
      ..state = Success(
        AccountMyInfoData(mid: 1, name: '原昵称', coins: 10, sign: '原签名'),
      );
  });
  tearDown(() => controller.dispose());
  tearDownAll(() async {
    Request.dio.close(force: true);
    await interceptor.close();
  });

  test('资料写入互斥，拒绝保留快照，可重试并只应用提交值', () async {
    final source = controller.state.data;
    final pending = controller.update(ProfileType.uname, '提交昵称');
    expect(controller.saving, true);
    expect((await controller.update(ProfileType.sign, '另一次')).isSuccess, false);
    await interceptor.waitForRequests(1);
    expect((requests.single.options.data as Map)['uname'], '提交昵称');
    requests.single.reply.complete({'code': -403, 'message': '拒绝'});
    expect((await pending).isSuccess, false);
    expect(source.name, '原昵称');
    expect(source.coins, 10);
    expect(controller.saving, false);
    final retry = controller.update(ProfileType.uname, '提交昵称');
    await interceptor.waitForRequests(2);
    requests.last.reply.complete({'code': 0});
    expect((await retry).isSuccess, true);
    expect(source.name, '提交昵称');
    expect(source.coins, 4);
  });

  test('刷新替换来源后迟到写入不能改新资料', () async {
    final old = controller.state.data;
    final pending = controller.update(ProfileType.sign, '迟到签名');
    await interceptor.waitForRequests(1);
    final refresh = controller.load();
    await interceptor.waitForRequests(2);
    requests[1].reply.complete(info('刷新昵称'));
    await refresh;
    requests[0].reply.complete({'code': 0});
    await pending;
    expect(controller.state.data.name, '刷新昵称');
    expect(controller.state.data.sign, isNull);
    expect(old.sign, '原签名');
  });

  test('同 UID 换凭据后旧查询失效，新查询仍能发布', () async {
    final first = controller.load();
    await interceptor.waitForRequests(1);
    Accounts.replaceCredentials(login('new'));
    await interceptor.waitForRequests(2);
    expect(requests[0].options.extra['account'], isNot(same(Accounts.main)));
    requests[1].reply.complete(info('新账号昵称'));
    await Future<void>.delayed(Duration.zero);
    requests[0].reply.complete(info('旧凭据昵称'));
    await first;
    expect(controller.state.data.name, '新账号昵称');
  });

  test('写入待确认阻止再次提交，查询核对后同值不再扣币', () async {
    final pending = controller.update(ProfileType.uname, '新昵称');
    await interceptor.waitForRequests(1);
    requests.single.reply.complete({'private': 'damaged'});
    expect(await pending, isA<UnknownResult>());
    expect(controller.needsVerification, true);
    expect(
      (await controller.update(ProfileType.uname, '新昵称')).isSuccess,
      false,
    );
    expect(requests, hasLength(1));
    final refresh = controller.load();
    await interceptor.waitForRequests(2);
    requests.last.reply.complete(info('新昵称'));
    await refresh;
    expect(controller.needsVerification, false);
    expect(
      (await controller.update(ProfileType.uname, '新昵称')).isSuccess,
      false,
    );
    expect(requests, hasLength(2));
  });

  test('本地缓存同步失败不覆盖远端更新成功', () async {
    await cache.put('userInfoCache', UserInfoData(mid: 1, uname: '原昵称'));
    cache.fail = true;
    final pending = controller.update(ProfileType.uname, '新昵称');
    await interceptor.waitForRequests(1);
    requests.single.reply.complete({'code': 0});
    expect((await pending).isSuccess, true);
    expect(controller.state.data.name, '新昵称');
    expect(controller.state.data.coins, 4);
    expect(controller.saving, false);
  });

  test('刷新期间旧写入待确认仍要求再次核对，不随快照替换解除', () async {
    final pending = controller.update(ProfileType.uname, '新昵称');
    await interceptor.waitForRequests(1);
    final refresh = controller.load();
    await interceptor.waitForRequests(2);
    requests.last.reply.complete(info('查询快照'));
    await refresh;
    requests.first.reply.complete({'damaged': true});
    expect(await pending, isA<UnknownResult>());
    expect(controller.needsVerification, true);
    expect(
      (await controller.update(ProfileType.uname, '新昵称')).isSuccess,
      false,
    );
    expect(requests, hasLength(2));
  });

  test('核对查询缺少上次修改字段时仍阻止重复提交', () async {
    final pending = controller.update(ProfileType.uname, '新昵称');
    await interceptor.waitForRequests(1);
    requests.single.reply.complete({'damaged': true});
    expect(await pending, isA<UnknownResult>());
    final refresh = controller.load();
    await interceptor.waitForRequests(2);
    requests.last.reply.complete({
      'code': 0,
      'data': {'mid': 1, 'coins': 10},
    });
    await refresh;
    expect(controller.state, isA<Error>());
    expect(controller.needsVerification, true);
    expect(
      (await controller.update(ProfileType.uname, '新昵称')).isSuccess,
      false,
    );
    expect(requests, hasLength(2));
  });

  test('释放后迟到响应不发布状态或通知', () async {
    final pending = controller.load();
    await interceptor.waitForRequests(1);
    var notified = 0;
    final disposed = controller
      ..addListener(() => notified++)
      ..dispose();
    controller = MemberProfileController();
    requests.single.reply.complete(info('迟到'));
    await pending;
    expect(disposed.state, isA<Loading>());
    expect(notified, 0);
  });
}
