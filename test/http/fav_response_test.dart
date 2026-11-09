import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pili_aurora/http/fav.dart';
import 'package:pili_aurora/http/init.dart';
import 'package:pili_aurora/http/loading_state.dart';
import 'package:pili_aurora/models/common/account_type.dart';
import 'package:pili_aurora/utils/accounts.dart';
import 'package:pili_aurora/utils/accounts/account.dart';
import 'package:pili_aurora/utils/storage.dart';
import 'package:pili_aurora/utils/storage_key.dart';

import '../support/memory_box.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  Object? body;
  bool failTransport = false;
  void Function()? beforeResponse;
  final requests = <RequestOptions>[];
  final account = LoginAccount(
    BiliCookieJar.fromJson({'DedeUserID': '1', 'bili_jct': 'synthetic-csrf'}),
    null,
    null,
  );
  late Account previous;
  setUpAll(() {
    GStorage.setting = MemoryBox();
    GStorage.video = MemoryBox();
    GStorage.localCache = MemoryBox({
      LocalCacheKey.mixinKey: 'synthetic',
      LocalCacheKey.timeStamp: DateTime.now().millisecondsSinceEpoch,
    });
    previous = Accounts.main;
    Request();
    Request.dio.interceptors
      ..clear()
      ..add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            requests.add(options);
            beforeResponse?.call();
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
    requests.clear();
    beforeResponse = null;
    failTransport = false;
    body = null;
  });
  tearDownAll(() {
    Accounts.accountMode[AccountType.main.index] = previous;
    Request.dio.close(force: true);
  });
  final queries = <String, Future<LoadingState<dynamic>> Function()>{
    '详情': () => FavHttp.userFavFolderDetail(mediaId: 1, pn: 1, ps: 20),
    '订阅内容': () => FavHttp.favSeasonList(id: 1, pn: 1, ps: 20),
    '课程': () => FavHttp.favPugv(mid: 1, page: 1),
    '话题': () => FavHttp.favTopic(page: 1),
    '文章': () => FavHttp.favArticle(page: 1),
    '公开笔记': () => FavHttp.userNoteList(page: 1),
    '私人笔记': () => FavHttp.noteList(page: 1),
    '番剧': () => FavHttp.favPgc(type: 1, pn: 1),
    '收藏夹列表': () => FavHttp.userfavFolder(pn: 1, ps: 20, mid: 1),
    '收藏夹信息': () => FavHttp.favFolderInfo(mediaId: 1),
    '空间收藏': () => FavHttp.spaceFav(mid: 1),
    '全部收藏夹': () => FavHttp.allFavFolders(1),
    '视频所在收藏夹': () => FavHttp.videoInFolder(mid: 1, rid: 42, type: 2),
    '订阅视频可用性': () => FavHttp.subscriptionVideoAvailable(42),
  };
  final writes = <String, Future<LoadingState<dynamic>> Function()>{
    '收藏收藏夹': () => FavHttp.favFavFolder(1),
    '取消收藏夹': () => FavHttp.unfavFavFolder(1),
    '取消合集订阅': () => FavHttp.cancelSub(id: 1, type: 21),
    '取消收藏夹订阅': () => FavHttp.cancelSub(id: 1, type: 11),
    '收藏课程': () => FavHttp.addFavPugv(1),
    '取消课程': () => FavHttp.delFavPugv(1),
    '收藏话题': () => FavHttp.addFavTopic(1),
    '取消话题': () => FavHttp.delFavTopic(1),
    '话题点赞': () => FavHttp.likeTopic(1, false),
    '收藏文章': () => FavHttp.addFavArticle(id: 1),
    '取消文章': () => FavHttp.delFavArticle(id: 1),
    '删除私人笔记': () => FavHttp.delNote(isPublish: false, noteIds: '1'),
    '删除公开笔记': () => FavHttp.delNote(isPublish: true, noteIds: '1'),
    '收藏夹排序': () => FavHttp.sortFavFolder(sort: '1,2'),
    '内容排序': () => FavHttp.sortFav(mediaId: 1, sort: '1,2'),
    '清理收藏': () => FavHttp.cleanFav(mediaId: 1),
    '删除收藏夹': () => FavHttp.deleteFolder(mediaIds: '1'),
    for (final isAdd in [false, true])
      isAdd ? '创建收藏夹' : '修改收藏夹': () => FavHttp.addOrEditFolder(
        isAdd: isAdd,
        mediaId: isAdd ? null : 1,
        title: 'sample',
        privacy: 0,
        cover: '',
        intro: '',
      ),
    '订阅合集': () => FavHttp.seasonFav(isFav: false, seasonId: 1),
    '社区收藏': () => FavHttp.communityAction(opusId: 1, action: 3),
    '收藏视频': () => FavHttp.favVideo(resources: '42:2', addIds: '1'),
    '取消全部收藏': () => FavHttp.unfavAll(rid: 42, type: 2),
    for (final isFav in [false, true])
      for (final isCopy in [false, true])
        '转移 $isFav/$isCopy': () => FavHttp.copyOrMoveFav(
          isCopy: isCopy,
          isFav: isFav,
          srcMediaId: isFav ? 1 : null,
          tarMediaId: 2,
          resources: '42:2',
        ),
  };

  for (final query in queries.entries) {
    test('${query.key}损坏响应作为错误返回，保留解析原因和堆栈', () async {
      body = {'code': 0, 'data': 'private malformed data'};
      final result = await query.value() as Error;
      expect(result, isNot(isA<UnknownResult>()));
      expect(result.cause, isNotNull);
      expect(result.stackTrace, isNotNull);
      expect(result.toString(), isNot(contains('private')));
    });
  }
  for (final write in writes.entries) {
    test('${write.key}确认成功后才返回成功，损坏响应与传输失败均待确认', () async {
      body = {
        'code': 0,
        'data': {'id': 1, 'title': 'sample', 'attr': 2},
      };
      expect(await write.value(), isA<Success>());
      expect(requests.last.method, 'POST');
      expect(requests.last.extra['noRetry'], isTrue);
      expect(requests.last.extra['account'], same(account));
      body = {'message': 'missing status'};
      final malformed = await write.value() as UnknownResult;
      expect(malformed.cause, isA<FormatException>());
      failTransport = true;
      final failed = await write.value() as UnknownResult;
      expect(failed.cause, isA<DioException>());
      expect(failed.stackTrace, isNotNull);
    });
  }

  test('所有收藏接口保留业务拒绝码，缺失消息不误报未登录', () async {
    body = {'code': -403};
    for (final invoke in [...queries.values, ...writes.values]) {
      final result = await invoke() as Error;
      expect(result, isNot(isA<UnknownResult>()));
      expect(result.code, -403);
      expect(result.toString(), contains('-403'));
      expect(result.toString(), isNot(contains('未登录')));
    }
  });

  test('笔记和空间列表保留可空与空列表的区别', () async {
    for (final query in [FavHttp.userNoteList, FavHttp.noteList]) {
      body = {'code': 0, 'data': null};
      expect((await query(page: 1)).data, isNull);
      body = {
        'code': 0,
        'data': {'list': []},
      };
      expect((await query(page: 1)).data, isEmpty);
    }
    body = {'code': 0, 'data': null};
    expect((await FavHttp.spaceFav(mid: 1)).data, isNull);
    body = {'code': 0, 'data': []};
    expect((await FavHttp.spaceFav(mid: 1)).data, isEmpty);
  });

  test('创建缺失 ID 的响应待确认，查询缺失 ID 的响应作为格式错误', () async {
    body = {'code': 0, 'data': {}};
    expect(await writes['创建收藏夹']!(), isA<UnknownResult>());
    expect(await writes['修改收藏夹']!(), isA<UnknownResult>());
    final query = await FavHttp.favFolderInfo(mediaId: 1) as Error;
    expect(query, isNot(isA<UnknownResult>()));
    expect(query.cause, isA<FormatException>());
  });

  test('只有明确不存在的视频才能判定不可用，其他失败继续保留', () async {
    body = {'code': -404};
    expect((await FavHttp.subscriptionVideoAvailable(42)).data, isFalse);
    body = {'code': 0, 'data': {}};
    expect((await FavHttp.subscriptionVideoAvailable(42)).data, isTrue);
    body = {'code': -352, 'message': '需要验证'};
    expect((await FavHttp.subscriptionVideoAvailable(42) as Error).code, -352);
    failTransport = true;
    expect(await FavHttp.subscriptionVideoAvailable(42), isA<Error>());
  });

  test('拦截器执行前固定账号，切号不会让旧 CSRF 配上新 Cookie', () async {
    final replacement = LoginAccount(
      BiliCookieJar.fromJson({
        'DedeUserID': '2',
        'bili_jct': 'replacement-csrf',
      }),
      null,
      null,
    );
    beforeResponse = () =>
        Accounts.accountMode[AccountType.main.index] = replacement;
    body = {'code': 0};
    await FavHttp.favVideo(resources: '42:2', addIds: '1');
    expect(requests.single.extra['account'], same(account));
    expect((requests.single.data as Map)['csrf'], 'synthetic-csrf');
    beforeResponse = null;
    await FavHttp.unfavAll(account: account, rid: 42, type: 2);
    expect(requests.last.extra['account'], same(account));
    expect((requests.last.data as Map)['csrf'], 'synthetic-csrf');
  });
}
