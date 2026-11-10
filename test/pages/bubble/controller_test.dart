import 'package:flutter_test/flutter_test.dart';
import 'package:pili_aurora/http/init.dart';
import 'package:pili_aurora/http/loading_state.dart';
import 'package:pili_aurora/models/common/account_type.dart';
import 'package:pili_aurora/pages/bubble/controller.dart';
import 'package:pili_aurora/utils/accounts.dart';
import 'package:pili_aurora/utils/accounts/account.dart';
import 'package:pili_aurora/utils/storage.dart';

import '../../support/controlled_interceptor.dart';
import '../../support/memory_box.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late ControlledInterceptor interceptor;
  late BubbleController controller;
  LoginAccount login(String credential) => LoginAccount(
    BiliCookieJar.fromJson({'DedeUserID': '100', 'bili_jct': credential}),
    'access-$credential',
    null,
  )..activated = true;
  Map<String, Object> response(String id) => {
    'code': 0,
    'data': {
      'content': {
        'dyn_list': [
          {'dyn_id': id, 'title': id},
        ],
      },
    },
  };
  setUpAll(() {
    GStorage.setting = MemoryBox<dynamic>();
    GStorage.localCache = MemoryBox<dynamic>();
    Accounts.account = MemoryBox<LoginAccount>();
    AnonymousAccount().activated = true;
    Request();
    Request.dio.interceptors.clear();
  });
  setUp(() {
    interceptor = ControlledInterceptor();
    Request.dio.interceptors.add(interceptor);
    Accounts.accountMode[AccountType.main.index] = login('old');
    controller = BubbleController(null, tribeId: '1')..onInit();
  });
  tearDown(() async {
    controller.onClose();
    for (final request in interceptor.requests) {
      if (!request.reply.isCompleted) {
        request.reply.complete(response('retired'));
      }
    }
    Request.dio.interceptors.remove(interceptor);
    await interceptor.close();
    Accounts.accountMode[AccountType.main.index] = AnonymousAccount();
  });
  test('同 UID 换凭据后立即重读首页，丢弃旧账号响应', () async {
    await interceptor.waitForRequests(1);
    final oldAccount = Accounts.main;
    final newAccount = login('new');
    Accounts.replaceCredentials(newAccount);
    await interceptor.waitForRequests(2);
    expect(interceptor.requests[0].options.extra['account'], same(oldAccount));
    expect(interceptor.requests[1].options.extra['account'], same(newAccount));
    interceptor.requests[1].reply.complete(response('new'));
    await Future<void>.delayed(Duration.zero);
    interceptor.requests[0].reply.complete(response('old'));
    await Future<void>.delayed(Duration.zero);
    expect(controller.loadingState.value.data!.single.dynId, 'new');
    expect(controller.page, 2);
  });
  test('分页失败保留列表和页码，排序使迟到分页失效', () async {
    await interceptor.waitForRequests(1);
    interceptor.requests[0].reply.complete(response('first'));
    await Future<void>.delayed(Duration.zero);
    final failed = controller.onLoadMore();
    await interceptor.waitForRequests(2);
    interceptor.requests[1].reply.complete({'code': -1, 'message': '失败'});
    await failed;
    expect(controller.page, 2);
    expect(controller.loadingState.value.data!.single.dynId, 'first');
    final pending = controller.onLoadMore();
    await interceptor.waitForRequests(3);
    final sorted = controller.onSort(2);
    await interceptor.waitForRequests(4);
    expect(interceptor.requests[3].options.queryParameters['page_num'], 1);
    interceptor.requests[3].reply.complete(response('sorted'));
    await sorted;
    interceptor.requests[2].reply.complete(response('late'));
    await pending;
    expect(controller.loadingState.value.data!.single.dynId, 'sorted');
  });
  test('释放后消费迟到响应，不更新状态', () async {
    await interceptor.waitForRequests(1);
    controller.onClose();
    interceptor.requests[0].reply.complete(response('late'));
    await Future<void>.delayed(Duration.zero);
    expect(controller.loadingState.value, isA<Loading>());
    // tearDown 不再重复释放资源。
    controller = BubbleController(null, tribeId: 'unused');
  });
}
