import 'package:dio/dio.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pili_aurora/http/api.dart';
import 'package:pili_aurora/http/init.dart';
import 'package:pili_aurora/http/loading_state.dart';
import 'package:pili_aurora/http/search.dart';
import 'package:pili_aurora/models/common/account_type.dart';
import 'package:pili_aurora/models/common/search/search_type.dart';
import 'package:pili_aurora/models/search/result.dart';
import 'package:pili_aurora/utils/accounts.dart';
import 'package:pili_aurora/utils/accounts/account.dart';
import 'package:pili_aurora/utils/storage.dart';
import 'package:pili_aurora/utils/storage_key.dart';

import '../support/memory_box.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  Object? body;
  var failTransport = false;
  var switchWhileSigning = false;
  final requests = <RequestOptions>[];
  Account login(int mid) => LoginAccount(
    BiliCookieJar.fromJson({'DedeUserID': '$mid', 'bili_jct': 'fixture-$mid'}),
    null,
    null,
  );
  final account = login(1), replacement = login(2);
  final queries = <String, Future<LoadingState<dynamic>> Function()>{
    '联想': () => SearchHttp.searchSuggest(term: 'test'),
    for (final type in SearchType.values)
      type.name: () => SearchHttp.searchByType<SearchNumData>(
        searchType: type,
        account: account,
        keyword: 'test',
        page: 1,
      ),
    '番剧详情': () => SearchHttp.pgcInfo(seasonId: 1),
    '课堂详情': () => SearchHttp.pugvInfo(seasonId: 1),
    '热搜': SearchHttp.searchTrending,
    '推荐': SearchHttp.searchRecommend,
    '话题': () => SearchHttp.topicPubSearch(keywords: 'test', pageNum: 1),
  };
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
            requests.add(options);
            if (switchWhileSigning && options.path == Api.userInfo) {
              Accounts.accountMode[AccountType.recommend.index] = replacement;
              handler.resolve(
                Response(
                  requestOptions: options,
                  data: {
                    'code': 0,
                    'data': {
                      'wbi_img': {
                        'img_url': 'https://example.invalid/${'a' * 32}.png',
                        'sub_url': 'https://example.invalid/${'b' * 32}.png',
                      },
                    },
                  },
                ),
              );
            } else if (failTransport) {
              handler.reject(
                DioException(
                  requestOptions: options,
                  type: DioExceptionType.receiveTimeout,
                ),
              );
            } else {
              handler.resolve(Response(requestOptions: options, data: body));
            }
          },
        ),
      );
  });
  setUp(() async {
    body = null;
    failTransport = switchWhileSigning = false;
    requests.clear();
    Accounts.accountMode[AccountType.recommend.index] = account;
    await GStorage.localCache.putAll({
      LocalCacheKey.mixinKey: 'synthetic',
      LocalCacheKey.timeStamp: DateTime.now().millisecondsSinceEpoch,
    });
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

  test('所有搜索查询的损坏响应沿结果返回并保留原因与堆栈', () async {
    for (final invalid in [
      null,
      [],
      {'code': '0'},
      {'code': 0, 'data': 'private body', 'result': 'private body'},
    ]) {
      body = invalid;
      for (final entry in queries.entries) {
        final result = await entry.value() as Error;
        expect(result.cause, isNotNull, reason: entry.key);
        expect(result.stackTrace, isNotNull, reason: entry.key);
        expect(result.toString(), isNot(contains('private body')));
      }
    }
  });

  test('搜索查询保留明确拒绝码和传输异常，不把失败转为空列表', () async {
    for (final entry in queries.entries) {
      body = {'code': -403, 'msg': '请求被拒绝'};
      expect(
        await entry.value(),
        const Error('请求被拒绝', code: -403),
        reason: entry.key,
      );
      failTransport = true;
      final result = await entry.value() as Error;
      expect(result, isNot(isA<UnknownResult>()));
      expect(result.cause, isA<DioException>(), reason: entry.key);
      expect(result.stackTrace, isNotNull);
      failTransport = false;
    }
  });

  test('签名等待期间切号仍绑定发起时的推荐账号，签名失败保留原因', () async {
    await GStorage.localCache.clear();
    switchWhileSigning = true;
    body = {
      'code': 0,
      'data': {'result': <String, dynamic>{}},
    };
    expect(await SearchHttp.searchSuggest(term: 'test'), isA<Success>());
    expect(requests.last.path, Api.searchSuggest);
    expect(requests.last.extra['account'], same(account));
    expect(Accounts.get(AccountType.recommend), same(replacement));

    await GStorage.localCache.put(LocalCacheKey.timeStamp, 'invalid timestamp');
    final before = requests.length;
    expect(
      (await SearchHttp.searchSuggest(term: 'test') as Error).cause,
      isNotNull,
    );
    expect((await queries['video']!() as Error).cause, isNotNull);
    expect(requests, hasLength(before));
  });

  test('风控凭据必须完整，分类与热搜推荐保留正常空列表语义', () async {
    for (final voucher in ['', ' ', 42, []]) {
      body = {
        'code': 0,
        'data': {'v_voucher': voucher},
      };
      final result = await queries['video']!() as Error;
      expect(result, isNot(isA<SearchVerificationRequired>()));
      expect(result.cause, isNotNull);
    }
    body = {
      'code': 0,
      'data': {'v_voucher': 'voucher'},
    };
    expect(
      (await queries['video']!() as SearchVerificationRequired).voucher,
      'voucher',
    );
    body = {'code': 0, 'data': <String, dynamic>{}};
    for (final type in SearchType.values) {
      expect((await queries[type.name]!()).data.list, isNull);
    }
    expect((await SearchHttp.searchSuggest(term: 'test')), isA<Error>());
    body = {
      'code': 0,
      'data': {'result': <String, dynamic>{}},
    };
    expect((await SearchHttp.searchSuggest(term: 'test')).data.tag, isNull);
    body = {'code': 0, 'data': <String, dynamic>{}};
    expect((await SearchHttp.searchRecommend()).data.list, isNull);
    final trending = (await SearchHttp.searchTrending(needsTop: true)).data;
    expect(trending.list, isNull);
    expect(trending.topCount, 0);
    expect(
      (await SearchHttp.topicPubSearch(
        keywords: 'test',
        pageNum: 1,
      )).data.topicItems,
      isNull,
    );
  });

  test('番剧和课堂详情分别读取 result 与 data，话题保留分页参数', () async {
    body = {
      'code': 0,
      'result': {'season_id': 1},
      'data': {'season_id': 2},
    };
    expect((await SearchHttp.pgcInfo(seasonId: 1)).data.seasonId, 1);
    expect((await SearchHttp.pugvInfo(epId: 2)).data.seasonId, 2);
    body = {'code': 0, 'data': <String, dynamic>{}};
    await SearchHttp.topicPubSearch(keywords: 'test', pageNum: 2);
    expect(requests.last.queryParameters['offset'], 20);
    expect(requests.last.queryParameters.containsKey('page_num'), isFalse);
  });

  testWidgets('分 P 查询保留空列表和越界回退，损坏响应返回空值并显示可读失败', (tester) async {
    Future<T> resolved<T>(Future<T> request) async {
      var completed = false;
      final result = request.whenComplete(() => completed = true);
      final deadline = tester.binding.clock.now().add(
        const Duration(seconds: 3),
      );
      while (!completed && tester.binding.clock.now().isBefore(deadline)) {
        await tester.pump(const Duration(milliseconds: 1));
      }
      expect(completed, isTrue);
      return result;
    }

    await tester.pumpWidget(
      MaterialApp(
        builder: FlutterSmartDialog.init(),
        home: const Scaffold(),
      ),
    );
    body = {'code': 0, 'data': []};
    expect(await resolved(SearchHttp.ab2cWithDimension(aid: 1)), isNull);
    body = {
      'code': 0,
      'data': [
        {'cid': 2},
        {'cid': 3},
      ],
    };
    expect(await resolved(SearchHttp.ab2c(aid: 1, part: 2)), 3);
    expect(
      (await resolved(SearchHttp.ab2cWithDimension(aid: 1, part: 4)))?.cid,
      2,
    );
    body = {
      'code': 0,
      'data': [
        {'cid': 0},
      ],
    };
    expect(await resolved(SearchHttp.ab2cWithDimension(aid: 1)), isNull);
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('响应数据解析失败，请重试'), findsOneWidget);
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox());
  });
}
