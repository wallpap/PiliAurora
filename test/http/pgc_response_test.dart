import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pili_aurora/http/init.dart';
import 'package:pili_aurora/http/loading_state.dart';
import 'package:pili_aurora/http/pgc.dart';
import 'package:pili_aurora/models/common/account_type.dart';
import 'package:pili_aurora/models/common/pgc_review_type.dart';
import 'package:pili_aurora/utils/accounts.dart';
import 'package:pili_aurora/utils/accounts/account.dart';
import 'package:pili_aurora/utils/storage.dart';

import '../support/memory_box.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final account = LoginAccount(
    BiliCookieJar.fromJson({'DedeUserID': '1', 'bili_jct': 'synthetic-csrf'}),
    null,
    null,
  );
  late Account recommended;
  final requests = <RequestOptions>[];
  Object? body;
  bool failTransport = false;
  setUpAll(() {
    GStorage.setting = MemoryBox();
    GStorage.video = MemoryBox();
    GStorage.localCache = MemoryBox();
    recommended = AnonymousAccount();
    Request();
    Request.dio.interceptors
      ..clear()
      ..add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            requests.add(options);
            if (failTransport) {
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
  setUp(() {
    Accounts.accountMode[AccountType.main.index] = account;
    Accounts.accountMode[AccountType.recommend.index] = recommended;
    requests.clear();
    body = null;
    failTransport = false;
  });
  tearDownAll(() => Request.dio.close(force: true));

  final queries = <Future<LoadingState<dynamic>> Function()>[
    () => PgcHttp.pgcIndexResult(account: account, page: 1, params: {}),
    () => PgcHttp.pgcIndexCondition(account: account, type: 0),
    () => PgcHttp.pgcIndex(page: 1),
    () => PgcHttp.pgcTimeline(before: 6, after: 6),
    () => PgcHttp.pgcReview(type: PgcReviewType.short, mediaId: 1),
    () => PgcHttp.seasonStatus(1),
  ];
  final writes = <Future<LoadingState<void>> Function()>[
    () => PgcHttp.pgcReviewLike(mediaId: 1, reviewId: 2, account: account),
    () => PgcHttp.pgcReviewDislike(mediaId: 1, reviewId: 2, account: account),
    () => PgcHttp.pgcReviewPost(
      mediaId: 1,
      score: 8,
      content: '草稿',
      account: account,
    ),
    () => PgcHttp.pgcReviewMod(
      mediaId: 1,
      score: 8,
      content: '草稿',
      reviewId: 2,
      account: account,
    ),
    () => PgcHttp.pgcReviewDel(mediaId: 1, reviewId: 2, account: account),
  ];

  test('番剧接口保留明确业务拒绝与错误码', () async {
    body = {'code': -403, 'message': '拒绝请求'};
    for (final invoke in [...queries, ...writes]) {
      final error = await invoke() as Error;
      expect(error.code, -403);
      expect(error.toString(), '拒绝请求');
      expect(error, isNot(isA<UnknownResult>()));
    }
  });

  test('损坏查询响应和传输失败沿结果返回并保留原始原因', () async {
    body = {
      'code': 0,
      'data': 'private-response',
      'result': 'private-response',
    };
    for (final invoke in queries) {
      final error = await invoke() as Error;
      expect(error.cause, isNotNull);
      expect(error.stackTrace, isNotNull);
      expect(error.toString(), isNot(contains('private-response')));
    }
    failTransport = true;
    for (final invoke in queries) {
      final error = await invoke() as Error;
      expect(error.cause, isA<DioException>());
      expect(error, isNot(isA<UnknownResult>()));
    }
  });

  test('写入无回显仍成功，无法确认响应或传输时返回待确认且禁重试', () async {
    body = {'code': 0};
    for (final invoke in writes) {
      expect(await invoke(), isA<Success<void>>());
      expect(requests.last.method, 'POST');
      expect(requests.last.extra['noRetry'], isTrue);
      expect(requests.last.extra['account'], same(account));
      expect((requests.last.data as Map)['csrf'], 'synthetic-csrf');
    }
    body = {'message': 'missing-code'};
    for (final invoke in writes) {
      expect(await invoke(), isA<UnknownResult>());
    }
    failTransport = true;
    for (final invoke in writes) {
      final error = await invoke() as UnknownResult;
      expect(error.cause, isA<DioException>());
      expect(error.stackTrace, isNotNull);
    }
  });

  test('可空列表、评分统计和筛选内容保留空语义', () async {
    body = {'code': 0, 'data': <String, dynamic>{}, 'result': null};
    expect((await PgcHttp.pgcIndex()).data, isNull);
    expect((await PgcHttp.pgcTimeline(before: 0, after: 0)).data, isNull);
    final review = (await PgcHttp.pgcReview(
      type: PgcReviewType.short,
      mediaId: 1,
    )).data;
    expect(review.list, isNull);
    expect(review.count, isNull);
    expect(
      (await PgcHttp.pgcIndexCondition(account: account, type: 0)).data.filter,
      isNull,
    );
    expect(requests.first.extra['account'], same(recommended));
    expect(requests[1].extra['account'], same(account));
  });

  test('追番状态为明确类型，未关注可缺少分组，缺少关注标记返回解析错误', () async {
    body = {
      'code': 0,
      'result': {'follow': 0},
    };
    final status = (await PgcHttp.seasonStatus(1)).data;
    expect(status.followed, isFalse);
    expect(status.status, isNull);
    body = {
      'code': 0,
      'result': {'follow': 1, 'follow_status': 3},
    };
    expect((await PgcHttp.seasonStatus(1)).data.status, 3);
    body = {'code': 0, 'result': <String, dynamic>{}};
    final failure = await PgcHttp.seasonStatus(1) as Error;
    expect(failure.cause, isA<FormatException>());
  });

  test('非法评分或目标在请求分发前明确失败', () async {
    for (final result in [
      await PgcHttp.pgcReviewPost(mediaId: 1, score: 0, content: ''),
      await PgcHttp.pgcReviewMod(
        mediaId: 1,
        score: 7,
        content: '',
        reviewId: 2,
      ),
      await PgcHttp.pgcReviewLike(mediaId: 1, reviewId: 0),
      await PgcHttp.pgcReview(type: PgcReviewType.short, mediaId: ''),
      await PgcHttp.seasonStatus(0),
      await PgcHttp.pgcReview(type: PgcReviewType.short, mediaId: null),
    ]) {
      expect(result, isA<Error>());
      expect(result, isNot(isA<UnknownResult>()));
    }
    expect(requests, isEmpty);
  });
}
