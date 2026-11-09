import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pili_aurora/common/widgets/pair.dart';
import 'package:pili_aurora/http/init.dart';
import 'package:pili_aurora/http/loading_state.dart';
import 'package:pili_aurora/http/sponsor_block.dart';
import 'package:pili_aurora/models/common/sponsor_block/action_type.dart';
import 'package:pili_aurora/models/common/sponsor_block/post_segment_model.dart';
import 'package:pili_aurora/models/common/sponsor_block/segment_type.dart';
import 'package:pili_aurora/utils/accounts/account.dart';
import 'package:pili_aurora/utils/storage.dart';
import 'package:pili_aurora/utils/storage_key.dart';

import '../support/memory_box.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  Object? body;
  int status = 200;
  DioExceptionType? failure;
  final requests = <RequestOptions>[];
  final segments = [
    {
      'UUID': 'segment',
      'category': 'intro',
      'segment': [0, 2],
      'videoDuration': 60,
    },
  ];
  final draft = PostSegmentModel(
    segment: Pair(first: 0.0, second: 2.0),
    category: SegmentType.intro,
    actionType: ActionType.skip,
  );
  final queries =
      <
        ({
          String name,
          Future<LoadingState<dynamic>> Function() call,
          Object valid,
        })
      >[
        (
          name: '片段',
          call: () => SponsorBlock.getSkipSegments(bvid: 'video', cid: 1),
          valid: segments,
        ),
        (name: '状态', call: SponsorBlock.uptimeStatus, valid: '123.5'),
        (
          name: '统计',
          call: () => SponsorBlock.userInfo([
            'viewCount',
            'minutesSaved',
            'segmentCount',
          ]),
          valid: {'viewCount': 1, 'minutesSaved': 2.5, 'segmentCount': 3},
        ),
        (
          name: '绑定',
          call: () => SponsorBlock.getPortVideo(bvid: 'video', cid: 1),
          valid: {'ytbID': 'youtube'},
        ),
      ];
  final writes =
      <
        ({
          String name,
          Future<LoadingState<dynamic>> Function() call,
          Object valid,
        })
      >[
        (
          name: '投票',
          call: () => SponsorBlock.voteOnSponsorTime(uuid: 'segment', type: 1),
          valid: '',
        ),
        (
          name: '观看上报',
          call: () => SponsorBlock.viewedVideoSponsorTime('segment'),
          valid: '',
        ),
        (
          name: '提交片段',
          call: () => SponsorBlock.postSkipSegments(
            bvid: 'video',
            cid: 1,
            videoDuration: 60,
            segments: [draft],
          ),
          valid: segments,
        ),
        (
          name: '创建绑定',
          call: () => SponsorBlock.postPortVideo(
            bvid: 'video',
            cid: 1,
            ytbId: 'youtube',
            videoDuration: 60,
          ),
          valid: {'UUID': 'binding'},
        ),
      ];

  setUpAll(() {
    GStorage.setting = MemoryBox({SettingBoxKey.blockUserID: 'synthetic-user'});
    GStorage.video = MemoryBox();
    Request();
    Request.dio.interceptors
      ..clear()
      ..add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            requests.add(options);
            if (failure case final type?) {
              handler.reject(DioException(requestOptions: options, type: type));
            } else {
              handler.resolve(
                Response(
                  requestOptions: options,
                  statusCode: status,
                  data: body,
                ),
              );
            }
          },
        ),
      );
  });
  setUp(() async {
    requests.clear();
    status = 200;
    body = null;
    failure = null;
    await GStorage.setting.delete(SettingBoxKey.blockServer);
  });
  tearDownAll(() => Request.dio.close(force: true));

  for (final query in queries) {
    test('${query.name}：合法响应可消费，格式错误交付原因和堆栈', () async {
      body = query.valid;
      expect(await query.call(), isA<Success>());
      expect(requests.single.method, 'GET');
      expect(requests.single.extra['account'], isA<NoAccount>());
      body = 'private raw response';
      final error = await query.call() as Error;
      expect(error, isNot(isA<UnknownResult>()));
      expect(error.cause, isNotNull);
      expect(error.stackTrace, isNotNull);
      expect(error.toString(), isNot(contains('private')));
    });
  }
  for (final write in writes) {
    test('${write.name}：确认成功，传输中断与服务端错误不允许重放', () async {
      body = write.valid;
      expect(await write.call(), isA<Success>());
      expect(requests.single.method, 'POST');
      expect(requests.single.extra['account'], isA<NoAccount>());
      expect(requests.single.extra['noRetry'], isTrue);
      failure = DioExceptionType.receiveTimeout;
      final uncertain = await write.call() as UnknownResult;
      expect(uncertain.cause, isA<DioException>());
      expect(uncertain.stackTrace, isNotNull);
      failure = null;
      for (final code in [408, 500, 502]) {
        status = code;
        final result = await write.call() as UnknownResult;
        expect((result.cause as Error).code, code);
      }
    });
  }

  test('所有接口保留明确拒绝的 HTTP 状态，不向用户展示响应正文', () async {
    for (final entry in [...queries, ...writes]) {
      for (final code in [400, 403, 404, 409, 429]) {
        status = code;
        body = 'private raw response';
        final result = await entry.call() as Error;
        expect(result, isNot(isA<UnknownResult>()));
        expect(result.code, code);
        expect(result.toString(), isNot(contains('private')));
      }
    }
  });

  test('片段空列表成功；缺少绑定 ID 与损坏提交列表不能伪装成功', () async {
    body = [];
    expect(
      (await SponsorBlock.getSkipSegments(bvid: 'video', cid: 1)).data,
      isEmpty,
    );
    body = <String, dynamic>{};
    expect(
      await SponsorBlock.getPortVideo(bvid: 'video', cid: 1),
      isA<Error>(),
    );
    expect(await writes.last.call(), isA<UnknownResult>());
    expect(await writes[2].call(), isA<UnknownResult>());
    body = {'UUID': ' '};
    expect(await writes.last.call(), isA<UnknownResult>());
  });

  test('统计拒绝非有限时间与负数，避免展示阶段 round 失败', () async {
    for (final minutes in [double.infinity, double.nan, -1, null]) {
      body = {'viewCount': 1, 'minutesSaved': minutes, 'segmentCount': 1};
      expect(await SponsorBlock.userInfo([]), isA<Error>());
    }
  });

  test('查询传输失败沿返回值交付，不丢失 Dio 原因', () async {
    failure = DioExceptionType.connectionError;
    for (final query in queries) {
      final result = await query.call() as Error;
      expect(result, isNot(isA<UnknownResult>()));
      expect(result.cause, isA<DioException>());
      expect(result.stackTrace, isNotNull);
    }
  });

  test('无效投票与片段在发出请求前返回普通失败', () async {
    expect(await SponsorBlock.voteOnSponsorTime(uuid: 'segment'), isA<Error>());
    expect(
      await SponsorBlock.voteOnSponsorTime(
        uuid: 'segment',
        type: 1,
        category: SegmentType.intro,
      ),
      isA<Error>(),
    );
    expect(await SponsorBlock.viewedVideoSponsorTime(''), isA<Error>());
    expect(
      await SponsorBlock.postSkipSegments(
        bvid: 'video',
        cid: 1,
        videoDuration: 60,
        segments: [],
      ),
      isA<Error>(),
    );
    final invalid = PostSegmentModel(
      segment: Pair(first: 3.0, second: 1.0),
      category: SegmentType.intro,
      actionType: ActionType.skip,
    );
    final result = await SponsorBlock.postSkipSegments(
      bvid: 'video',
      cid: 1,
      videoDuration: 60,
      segments: [invalid],
    );
    expect(result, isA<Error>());
    expect(result, isNot(isA<UnknownResult>()));
    expect(requests, isEmpty);
  });

  test('错误服务器地址返回本地失败，URL 规范化保留代理前缀', () async {
    await GStorage.setting.put(SettingBoxKey.blockServer, 'invalid');
    expect(await writes.first.call(), isNot(isA<UnknownResult>()));
    expect(requests, isEmpty);
    await GStorage.setting.put(
      SettingBoxKey.blockServer,
      'https://example.test/proxy/',
    );
    body = '';
    expect(await writes.first.call(), isA<Success>());
    expect(requests.single.uri.path, '/proxy/api/voteOnSponsorTime');
  });
}
