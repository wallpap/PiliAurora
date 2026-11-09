import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pili_aurora/http/init.dart';
import 'package:pili_aurora/http/loading_state.dart';
import 'package:pili_aurora/http/search.dart';
import 'package:pili_aurora/models/common/search/search_type.dart';
import 'package:pili_aurora/models/search/result.dart';
import 'package:pili_aurora/utils/accounts/account.dart';
import 'package:pili_aurora/utils/storage.dart';
import 'package:pili_aurora/utils/storage_key.dart';

import '../support/memory_box.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  Object? body;
  setUpAll(() {
    GStorage.setting = MemoryBox<dynamic>();
    GStorage.localCache = MemoryBox<dynamic>({
      LocalCacheKey.mixinKey: 'synthetic',
      LocalCacheKey.timeStamp: DateTime.now().millisecondsSinceEpoch,
    });
    Request();
    Request.dio.interceptors
      ..clear()
      ..add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            handler.resolve(Response(requestOptions: options, data: body));
          },
        ),
      );
  });
  tearDownAll(() => Request.dio.close(force: true));

  test('分类搜索的成功响应缺失 data 时返回可重试错误', () async {
    for (final data in [null, 'invalid', []]) {
      body = {'code': 0, 'data': data};
      final result = await SearchHttp.searchByType<SearchVideoData>(
        searchType: SearchType.video,
        account: const NoAccount(),
        keyword: 'test',
        page: 1,
      );
      expect(result, isA<Error>());
      expect(result.toString(), '响应数据解析失败，请重试');
      expect((result as Error).cause, isNotNull);
    }
  });

  test('联想解析失败不受调试模式影响，业务失败保留原因', () async {
    body = {
      'code': 0,
      'data': {'result': 42},
    };
    final malformed = await SearchHttp.searchSuggest(term: 'test');
    expect(malformed, isA<Error>());
    expect(malformed.toString(), '响应数据解析失败，请重试');
    body = {'code': -1, 'message': '请求过于频繁'};
    final rejected = await SearchHttp.searchSuggest(term: 'test');
    expect(rejected, const Error('请求过于频繁', code: -1));
  });
}
