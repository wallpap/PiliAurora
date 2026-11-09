import 'package:flutter_test/flutter_test.dart';
import 'package:pili_aurora/http/api.dart';
import 'package:pili_aurora/http/init.dart';
import 'package:pili_aurora/http/loading_state.dart';
import 'package:pili_aurora/models/common/account_type.dart';
import 'package:pili_aurora/pages/live_emote/controller.dart';
import 'package:pili_aurora/utils/accounts.dart';
import 'package:pili_aurora/utils/accounts/account.dart';
import 'package:pili_aurora/utils/storage.dart';

import '../../support/controlled_interceptor.dart';
import '../../support/memory_box.dart';

class _Emotes extends LiveEmotePanelController {
  _Emotes() : super(12);

  final queries = <Future<void>>[];

  @override
  Future<void> queryData([bool isRefresh = true]) {
    final query = super.queryData(isRefresh);
    queries.add(query);
    return query;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final interceptor = ControlledInterceptor();
  final requests = interceptor.requests;
  LoginAccount account(String csrf) => LoginAccount(
    BiliCookieJar.fromJson({'DedeUserID': '1', 'bili_jct': csrf}),
    null,
    null,
  );
  Map<String, dynamic> emotes(String cover) => {
    'code': 0,
    'data': {
      'data': [
        {'current_cover': cover},
      ],
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
  tearDownAll(() async {
    Request.dio.close(force: true);
    await interceptor.close();
  });

  test('直播表情绑定主账号，凭据替换后拒绝旧结果并释放旧页签', () async {
    final original = account('original');
    Accounts.accountMode[AccountType.main.index] = original;
    final controller = _Emotes()..onInit();
    addTearDown(() {
      if (!controller.isClosed) controller.onDelete();
    });
    await interceptor.waitForRequests(1);
    expect(requests.single.options.path, Api.getLiveEmoticons);
    expect(requests.single.options.extra['account'], same(original));
    final replacement = account('replacement');
    Accounts.replaceCredentials(replacement);
    await interceptor.waitForRequests(2);
    expect(requests.last.options.extra['account'], same(replacement));
    requests.last.reply.complete(emotes('new'));
    await controller.queries[1];
    final refresh = controller.onRefresh();
    await interceptor.waitForRequests(3);
    expect(controller.loadingState.value.data?.single.currentCover, 'new');
    final previousTabs = controller.tabController!;
    requests.last.reply.complete(emotes('refreshed'));
    await refresh;
    expect(previousTabs.animation, isNull);
    requests.first.reply.complete(emotes('old'));
    await controller.queries.first;
    expect(
      controller.loadingState.value.data?.single.currentCover,
      'refreshed',
    );
    expect(controller.loadingState.value, isA<Success>());
    final lastTabs = controller.tabController!;
    controller.onDelete();
    expect(lastTabs.animation, isNull);
    Accounts.replaceCredentials(account('after-close'));
    expect(requests, hasLength(3));
  });
}
