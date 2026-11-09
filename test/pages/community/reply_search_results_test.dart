import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pili_aurora/grpc/bilibili/main/community/reply/v1.pb.dart';
import 'package:pili_aurora/grpc/grpc_req.dart';
import 'package:pili_aurora/http/init.dart';
import 'package:pili_aurora/http/loading_state.dart';
import 'package:pili_aurora/models/common/account_type.dart';
import 'package:pili_aurora/pages/video/reply_search_item/controller.dart';
import 'package:pili_aurora/utils/accounts.dart';
import 'package:pili_aurora/utils/accounts/account.dart';
import 'package:pili_aurora/utils/storage.dart';

import '../../support/controlled_interceptor.dart';
import '../../support/memory_box.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final interceptor = ControlledInterceptor(
    headers: Headers.fromMap({
      'grpc-status': ['0'],
    }),
  );
  final requests = interceptor.requests;
  LoginAccount account(String csrf) => LoginAccount(
    BiliCookieJar.fromJson({'DedeUserID': '1', 'bili_jct': csrf}),
    null,
    null,
  )..activated = true;

  setUpAll(() {
    GStorage.setting = MemoryBox();
    GStorage.video = MemoryBox();
    GStorage.localCache = MemoryBox();
    Request();
    Request.dio.interceptors
      ..clear()
      ..add(interceptor);
  });
  setUp(() {
    Accounts.accountMode[AccountType.main.index] = account('old');
    requests.clear();
  });
  tearDown(Get.reset);
  tearDownAll(() async {
    Request.dio.close(force: true);
    await interceptor.close();
  });
  Future<void> until(WidgetTester tester, bool Function() condition) async {
    final end = tester.binding.clock.now().add(const Duration(seconds: 3));
    while (!condition() && tester.binding.clock.now().isBefore(end)) {
      await tester.pump(const Duration(milliseconds: 1));
    }
    expect(condition(), isTrue);
  }

  Object result(String url) => GrpcReq.compressProtobuf(
    SearchItemReply(
      cursor: SearchItemCursorReply(hasNext: true),
      items: [SearchItem(url: url)],
    ).writeToBuffer(),
  );

  testWidgets('评论内容搜索固定已提交词，换凭据拒绝旧分页并释放子控制器', (tester) async {
    await tester.pumpWidget(const GetMaterialApp(home: SizedBox()));
    final controller = Get.put(ReplySearchController(1, 1), tag: 'search');
    final video = controller.videoCtr;
    final article = controller.articleCtr;
    await until(tester, () => requests.length == 2);
    for (final request in requests) {
      request.reply.complete(result('initial'));
    }
    await until(tester, () => !video.isLoading && !article.isLoading);
    controller.editingController.text = '已提交';
    controller.submit();
    await until(tester, () => requests.length == 4);
    for (final request in requests.skip(2)) {
      request.reply.complete(result('submitted'));
    }
    await until(tester, () => !video.isLoading && !article.isLoading);
    controller.editingController.text = '正在编辑';
    final more = video.onLoadMore();
    await until(tester, () => requests.length == 5);
    final query = SearchItemReq.fromBuffer(
      GrpcReq.decompressProtobuf(requests.last.options.data),
    );
    expect(query.keyword, '已提交');
    expect(query.cursor.next.toInt(), 2);
    final replacement = account('new');
    Accounts.replaceCredentials(replacement);
    await until(tester, () => requests.length == 7);
    expect(requests[5].options.extra['account'], same(replacement));
    expect(requests[6].options.extra['account'], same(replacement));
    requests[4].reply.complete(result('old-page'));
    await more;
    expect(video.loadingState.value, isA<Loading>());
    requests[5].reply.complete(result('new-video'));
    requests[6].reply.complete(result('new-article'));
    await until(tester, () => !video.isLoading && !article.isLoading);
    expect(video.loadingState.value.dataOrNull!.single.url, 'new-video');
    expect(article.loadingState.value.dataOrNull!.single.url, 'new-article');
    Get.delete<ReplySearchController>(tag: 'search');
    expect(video.isClosed, isTrue);
    expect(article.isClosed, isTrue);
    Accounts.replaceCredentials(account('closed'));
    await tester.pump();
    expect(requests, hasLength(7));
    await tester.pumpWidget(const SizedBox());
  });
}
