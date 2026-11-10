import 'package:dio/dio.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pili_aurora/http/init.dart';
import 'package:pili_aurora/utils/app_scheme.dart';
import 'package:pili_aurora/utils/url_utils.dart';
import 'package:pili_aurora/utils/accounts/account.dart';
import 'package:pili_aurora/utils/storage.dart';

import '../support/memory_box.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  Object? body;
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
            if (options.method == 'HEAD') {
              expect(options.extra['account'], isA<AnonymousAccount>());
              if (body == 'fail') {
                handler.reject(
                  DioException(requestOptions: options, error: 'private-value'),
                );
              } else {
                handler.resolve(
                  Response(
                    requestOptions: options,
                    headers: Headers.fromMap({
                      'location': [body as String],
                    }),
                  ),
                );
              }
            } else {
              handler.resolve(Response(requestOptions: options, data: body));
            }
          },
        ),
      );
  });
  tearDown(Get.reset);
  tearDownAll(() => Request.dio.close(force: true));
  test('重定向相对路径按原URL解析，失败按调用方约定返回原链接或null', () async {
    body = '/video/123/';
    expect(
      await UrlUtils.parseRedirectUrl('https://b23.tv/short'),
      'https://b23.tv/video/123',
    );
    body = 'fail';
    const url = 'https://b23.tv/short?secret=private-value';
    expect(await UrlUtils.parseRedirectUrl(url), isNull);
    expect(await UrlUtils.parseRedirectUrl(url, true), url);
  });
  for (final response in [
    {'code': 0, 'data': []},
    {'code': -404, 'message': '视频不存在'},
    {
      'code': 0,
      'data': [
        {'cid': 'private-value'},
      ],
    },
  ]) {
    testWidgets('视频链接失败或空结果提供明确提示 $response', (tester) async {
      await tester.pumpWidget(
        GetMaterialApp(
          builder: FlutterSmartDialog.init(),
          home: const Scaffold(),
        ),
      );
      body = response;
      await tester.runAsync(
        () => PiliScheme.videoPush(123, null, showDialog: false),
      );
      await tester.pumpAndSettle();
      expect(find.text('获取中...'), findsNothing);
      expect(find.textContaining('private-value'), findsNothing);
      expect(
        find.text(
          response['code'] == -404
              ? '视频不存在'
              : (response['data'] as List).isEmpty
              ? '视频暂无可播放内容'
              : '响应数据解析失败，请重试',
        ),
        findsOneWidget,
      );
      final dismiss = SmartDialog.dismiss(status: .allToast);
      await tester.pumpAndSettle();
      await dismiss;
      await tester.pumpWidget(const SizedBox());
    });
  }
}
