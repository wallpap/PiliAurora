import 'package:flutter_test/flutter_test.dart';
import 'package:pili_aurora/http/api.dart';
import 'package:pili_aurora/http/init.dart';
import 'package:pili_aurora/http/loading_state.dart';
import 'package:pili_aurora/models/common/account_type.dart';
import 'package:pili_aurora/pages/video/member/controller.dart';
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
  Account account(int id) => LoginAccount(
    BiliCookieJar.fromJson({'DedeUserID': '$id', 'bili_jct': 'fixture-$id'}),
    null,
    null,
  );
  late Account original;
  Map<String, dynamic> info(String name) => {
    'code': 0,
    'data': {
      'mid': 3,
      'name': name,
      'vip': <String, dynamic>{},
    },
  };
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
    original = account(1);
    Accounts.accountMode[AccountType.main.index] = original;
    await GStorage.localCache.putAll({
      LocalCacheKey.mixinKey: 'fixture',
      LocalCacheKey.timeStamp: DateTime.now().millisecondsSinceEpoch,
    });
    requests.clear();
  });
  tearDownAll(() async {
    Request.dio.close(force: true);
    await interceptor.close();
  });

  test('成员资料可重试，旧查询不能覆盖新资料或派生统计', () async {
    final controller = HorizontalMemberPageController(mid: 3, currAid: null);
    final old = controller.getUserInfo();
    await interceptor.waitForRequests(1);
    final latest = controller.getUserInfo();
    await interceptor.waitForRequests(2);
    requests[1].reply.complete(info('新资料'));
    await interceptor.waitForRequests(4);
    requests[0].reply.complete(info('旧资料'));
    await old;
    requests[2].reply.complete({
      'code': 0,
      'data': {'follower': 10},
    });
    requests[3].reply.complete({
      'code': 0,
      'data': {'archive': 20},
    });
    await latest;
    expect(controller.userState.value.data.name, '新资料');
    expect(controller.userStat, {'follower': 10, 'archive': 20});
    expect(requests.skip(2).map((r) => r.options.path).toSet(), {
      Api.userStat,
      Api.getMemberViewApi,
    });
    for (final request in requests) {
      expect(request.options.extra['account'], same(original));
    }
    controller.onClose();
  });

  test('成员资料返回前切号不回写旧资料或继续请求统计', () async {
    final controller = HorizontalMemberPageController(mid: 3, currAid: null);
    final pending = controller.getUserInfo();
    await interceptor.waitForRequests(1);
    Accounts.accountMode[AccountType.main.index] = account(2);
    requests.single.reply.complete(info('旧账号资料'));
    await pending;
    expect(controller.userState.value, isA<Loading>());
    expect(requests, hasLength(1));
    expect(controller.userStat, isEmpty);
    controller.onClose();
  });

  test('关闭后的迟到统计由所属操作消费且不更新页面', () async {
    final controller = HorizontalMemberPageController(mid: 3, currAid: null);
    final pending = controller.getUserInfo();
    await interceptor.waitForRequests(1);
    requests.single.reply.complete(info('成员'));
    await interceptor.waitForRequests(3);
    controller.onClose();
    requests[1].reply.complete({
      'code': 0,
      'data': {'follower': 10},
    });
    requests[2].reply.complete({
      'code': 0,
      'data': {'archive': 20},
    });
    await pending;
    expect(controller.userStat, isEmpty);
    await controller.getUserInfo();
    expect(requests, hasLength(3));
  });

  test('统计解析失败不覆盖已确认资料或另一项统计成功', () async {
    final controller = HorizontalMemberPageController(mid: 3, currAid: null);
    final pending = controller.getUserInfo();
    await interceptor.waitForRequests(1);
    requests.single.reply.complete(info('成员'));
    await interceptor.waitForRequests(3);
    requests[1].reply.complete({'code': 0, 'data': 'private response'});
    requests[2].reply.complete({
      'code': 0,
      'data': {'archive': 20},
    });
    await pending;
    expect(controller.userState.value.data.name, '成员');
    expect(controller.userStat, {'archive': 20});
    controller.onClose();
  });
}
