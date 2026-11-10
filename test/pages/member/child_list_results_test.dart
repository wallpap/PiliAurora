import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:pili_aurora/http/init.dart';
import 'package:pili_aurora/http/loading_state.dart';
import 'package:pili_aurora/http/member.dart';
import 'package:pili_aurora/http/search.dart';
import 'package:pili_aurora/models/remote/space/space_archive/episodic_button.dart';
import 'package:pili_aurora/models/common/account_type.dart';
import 'package:pili_aurora/models/remote/space/space_archive/data.dart';
import 'package:pili_aurora/models/remote/space/space_archive/item.dart';
import 'package:pili_aurora/pages/common/common_controller.dart';
import 'package:pili_aurora/pages/member_video/controller.dart';
import 'package:pili_aurora/pages/member_opus/controller.dart';
import 'package:pili_aurora/pages/member_video_web/base/controller.dart';
import 'package:pili_aurora/utils/accounts.dart';
import 'package:pili_aurora/utils/accounts/account.dart';
import 'package:pili_aurora/utils/storage.dart';
import 'package:pili_aurora/utils/storage_key.dart';

import '../../support/controlled_interceptor.dart';
import '../../support/memory_box.dart';

class _Web extends BaseVideoWebCtr<SpaceArchiveData, SpaceArchiveItem, int> {
  _Web() : super(mid: 2);
  @override
  final order = 0.obs;
  @override
  List<SpaceArchiveItem>? getDataList(SpaceArchiveData response) =>
      response.item;
  @override
  Future<LoadingState<SpaceArchiveData>> customGetData() =>
      MemberHttp.spaceArchive(
        account: Accounts.main,
        type: .video,
        mid: 2,
      );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final interceptor = ControlledInterceptor();
  final requests = interceptor.requests;
  late CommonController<dynamic, dynamic> controller;
  LoginAccount account(String csrf) => LoginAccount(
    BiliCookieJar.fromJson({'DedeUserID': '1', 'bili_jct': csrf}),
    null,
    null,
  )..activated = true;
  Map<String, dynamic> page(String label, bool opus) => {
    'code': 0,
    'data': opus
        ? {
            'offset': label,
            'has_more': false,
            'items': [
              {'content': label, 'opus_id': label},
            ],
          }
        : {
            'count': 1,
            'has_next': false,
            'item': [
              {'param': label, 'title': label},
            ],
          },
  };
  Future<void> flush() async {
    for (var i = 0; i < 15; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  setUpAll(() {
    GStorage.setting = MemoryBox();
    GStorage.video = MemoryBox();
    GStorage.localCache = MemoryBox({
      LocalCacheKey.mixinKey: 'synthetic',
      LocalCacheKey.timeStamp: DateTime.now().millisecondsSinceEpoch,
    });
    Accounts.account = MemoryBox<LoginAccount>();
    Request();
    Request.dio.interceptors
      ..clear()
      ..add(interceptor);
  });
  setUp(() {
    requests.clear();
    Accounts.accountMode[AccountType.main.index] = account('old');
  });
  tearDown(() {
    controller.onDelete();
    Get.reset();
  });
  tearDownAll(() async {
    Request.dio.close(force: true);
    await interceptor.close();
  });
  for (final kind in ['video', 'opus', 'web']) {
    void create() {
      controller = switch (kind) {
        'video' => MemberVideoCtr(
          heroTag: null,
          type: .video,
          mid: 2,
          seasonId: null,
          seriesId: null,
        ),
        'opus' => MemberOpusController(heroTag: null, mid: 2),
        _ => _Web(),
      };
      controller.onStart();
    }

    String title() => kind == 'opus'
        ? (controller.loadingState.value.data as List).single.content as String
        : (controller.loadingState.value.data as List).single.title as String;
    test('$kind 同 UID 换凭据重新查询，拒绝旧响应且释放账号订阅', () async {
      create();
      await interceptor.waitForRequests(1);
      final old = Accounts.main;
      final replacement = account('new');
      Accounts.replaceCredentials(replacement);
      await interceptor.waitForRequests(2);
      expect(requests.first.options.extra['account'], same(old));
      expect(requests.last.options.extra['account'], same(replacement));
      requests.last.reply.complete(page('new', kind == 'opus'));
      await flush();
      expect(title(), 'new');
      requests.first.reply.complete(page('old', kind == 'opus'));
      await flush();
      expect(title(), 'new');
      expect(controller.isLoading, false);
      controller.onDelete();
      Accounts.replaceCredentials(account('closed'));
      await flush();
      expect(requests, hasLength(2));
    });
    test('$kind 首屏失败返回错误，可刷新重试，关闭不发布迟到结果', () async {
      create();
      await interceptor.waitForRequests(1);
      requests.first.reply.complete({'code': -403, 'message': '拒绝查询'});
      await flush();
      expect(controller.loadingState.value, isA<Error>());
      expect(controller.isLoading, false);
      final refresh = controller.onReload();
      await interceptor.waitForRequests(2);
      controller.onDelete();
      requests.last.reply.complete(page('late', kind == 'opus'));
      await refresh;
      expect(controller.loadingState.value, isA<Loading>());
    });
  }
  test('继续播放互斥，换凭据后的迟到查询失败不弹窗或打开视频', () async {
    final video = MemberVideoCtr(
      heroTag: null,
      type: .video,
      mid: 2,
      seasonId: null,
      seriesId: null,
    );
    controller = video;
    video.onStart();
    await interceptor.waitForRequests(1);
    requests.single.reply.complete(page('first', false));
    await flush();
    video.episodicButton = EpisodicButton(
      text: '继续播放',
      uri: 'bilibili://video?oid=1',
    );
    final opening = video.toViewPlayAll();
    await video.toViewPlayAll();
    await interceptor.waitForRequests(2);
    final original = Accounts.main;
    Accounts.replaceCredentials(account('replacement'));
    await interceptor.waitForRequests(3);
    requests[1].reply.complete({'code': -403, 'message': '旧账号失败'});
    await opening;
    expect(requests[1].options.extra['account'], same(original));
    requests[2].reply.complete(page('replacement', false));
    await flush();
    expect(video.loadingState.value.data!.single.title, 'replacement');
  });

  test('分 P 结果明确区分失败与空内容，交由调用方提示', () async {
    controller = _Web();
    var query = SearchHttp.pageWithDimension(aid: 1, account: Accounts.main);
    await interceptor.waitForRequests(1);
    requests.single.reply.complete({'code': -403, 'message': '拒绝查询'});
    expect(await query, isA<Error>());
    query = SearchHttp.pageWithDimension(aid: 1, account: Accounts.main);
    await interceptor.waitForRequests(2);
    requests.last.reply.complete({'code': 0, 'data': []});
    final empty = await query;
    expect(empty, isA<Success>());
    expect(empty.data, isNull);
  });
}
