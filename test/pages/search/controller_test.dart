import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart' hide Transition;
import 'package:pili_aurora/pages/search/view.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_ce/hive.dart';
import 'package:pili_aurora/http/init.dart';
import 'package:pili_aurora/http/loading_state.dart';
import 'package:pili_aurora/pages/search_trending/controller.dart';
import 'package:pili_aurora/pages/search_trending/view.dart';
import 'package:pili_aurora/common/widgets/sliver/trending_header.dart';
import 'package:pili_aurora/models/remote/search/search_trending/data.dart';
import 'package:pili_aurora/pages/search/controller.dart';
import 'package:pili_aurora/utils/storage.dart';
import 'package:pili_aurora/utils/storage_key.dart';

class _Box<T> implements Box<T> {
  final storedValues = <dynamic, T>{};
  final changes = StreamController<BoxEvent>.broadcast();
  @override
  Stream<BoxEvent> watch({dynamic key}) =>
      changes.stream.where((event) => key == null || key == event.key);
  @override
  T? get(dynamic key, {T? defaultValue}) => storedValues[key] ?? defaultValue;
  @override
  Future<void> put(dynamic key, T value) async {
    storedValues[key] = value;
  }

  @override
  Future<void> delete(dynamic key) async {
    storedValues.remove(key);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _TrendingNotifier extends SearchTrendingNotifier {
  @override
  LoadingState<SearchTrendingData> build() => const Error('fixture failure');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final requests = <Completer<Map<String, dynamic>>>[];
  final settings = _Box<dynamic>();
  late ProviderContainer container;
  late ProviderSubscription<SearchState> subscription;
  final provider = searchProvider('fixture');
  SearchNotifier getController() => container.read(provider.notifier);
  Future<void> dispatched(int count) async {
    while (requests.length < count) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  Map<String, dynamic> suggestions(List<String> terms) => {
    'code': 0,
    'data': {
      'result': {
        'tag': [
          for (final term in terms) {'term': term, 'name': term},
        ],
      },
    },
  };
  void query(String text) => getController().input(text, immediate: true);
  Future<void> flush() => Future<void>.delayed(Duration.zero);

  setUpAll(() {
    GStorage.setting = settings
      ..storedValues.addAll({
        SettingBoxKey.enableHotKey: false,
        SettingBoxKey.enableSearchRcmd: false,
      });
    GStorage.historyWord = _Box<dynamic>();
    GStorage.localCache = _Box<dynamic>()
      ..storedValues.addAll({
        LocalCacheKey.timeStamp: DateTime.now().millisecondsSinceEpoch,
        LocalCacheKey.mixinKey: 'fixture-mixin-key',
      });
    Request();
    Request.dio.interceptors.clear();
    Request.dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) async {
          final pending = Completer<Map<String, dynamic>>();
          requests.add(pending);
          handler.resolve(
            Response(requestOptions: options, data: await pending.future),
          );
        },
      ),
    );
  });
  setUp(() {
    requests.clear();
    settings.storedValues[SettingBoxKey.searchSuggestion] = true;
    container = ProviderContainer();
    subscription = container.listen(provider, (_, _) {});
  });
  tearDown(() {
    subscription.close();
    container.dispose();
  });
  tearDownAll(() => Request.dio.close(force: true));

  test('联想请求乱序返回时保留最新输入的结果，空结果清除旧建议', () async {
    query('old');
    await dispatched(1);
    query('latest');
    await dispatched(2);
    requests[1].complete(suggestions(['latest-result']));
    await flush();
    requests[0].complete(suggestions(['old-result']));
    await flush();
    expect(container.read(provider).suggestions.single.term, 'latest-result');
    query('none');
    await dispatched(3);
    requests[2].complete(suggestions([]));
    await flush();
    expect(container.read(provider).suggestions, isEmpty);
  });

  test('清空后重新输入相同词时，防抖开始前旧结果仍应失效', () async {
    query('same');
    await dispatched(1);
    getController().input('');
    getController().input('same');
    requests.single.complete(suggestions(['old-result']));
    await flush();
    expect(container.read(provider).suggestions, isEmpty);
  });

  test('禁用搜索建议时不发起查询，也不访问未初始化的列表', () async {
    subscription.close();
    container.dispose();
    settings.storedValues[SettingBoxKey.searchSuggestion] = false;
    container = ProviderContainer();
    subscription = container.listen(provider, (_, _) {});
    query('disabled');
    await flush();
    expect(requests, isEmpty);
  });

  test('关闭页面后忽略迟到的建议，不再发起新请求', () async {
    query('old');
    await dispatched(1);
    subscription.close();
    container.dispose();
    requests.single.complete(suggestions(['late-result']));
    await flush();

    expect(requests, hasLength(1));
  });
  test('历史在不同搜索页面之间共享', () {
    final second = container.listen(searchProvider('second'), (_, _) {});
    final history = container.read(searchHistoryProvider.notifier)
      ..replace([])
      ..add('first')
      ..add('second')
      ..add('first');
    expect(container.read(searchHistoryProvider), ['first', 'second']);
    history.remove('first');
    expect(container.read(searchHistoryProvider), ['second']);
    second.close();
  });

  test('热搜和推荐刷新丢弃先前请求', () async {
    final search = getController();
    final oldTrending = search.refreshTrending();
    final oldRecommend = search.refreshRecommend();
    await dispatched(2);
    final newTrending = search.refreshTrending();
    final newRecommend = search.refreshRecommend();
    await dispatched(4);
    requests[2].complete({'code': -1, 'message': 'new trending'});
    requests[3].complete({'code': -1, 'message': 'new recommend'});
    await Future.wait([newTrending, newRecommend]);
    requests[0].complete({'code': -1, 'message': 'old trending'});
    requests[1].complete({'code': -1, 'message': 'old recommend'});
    await Future.wait([oldTrending, oldRecommend]);
    expect((container.read(provider).trending as Error).errMsg, 'new trending');
    expect(
      (container.read(provider).recommend as Error).errMsg,
      'new recommend',
    );
  });

  test('完整热搜刷新丢弃先前请求', () async {
    final sub = container.listen(searchTrendingProvider, (_, _) {});
    await dispatched(1);
    final refresh = container.read(searchTrendingProvider.notifier).refresh();
    await dispatched(2);
    requests[1].complete({'code': -1, 'message': 'new'});
    await refresh;
    requests[0].complete({'code': -1, 'message': 'old'});
    await flush();
    expect((container.read(searchTrendingProvider) as Error).errMsg, 'new');
    sub.close();
  });
  test('外部设置变更同步到共享历史开关', () async {
    final sub = container.listen(recordSearchHistoryProvider, (_, _) {});
    settings.storedValues[SettingBoxKey.recordSearchHistory] = false;
    settings.changes.add(
      const BoxEvent(SettingBoxKey.recordSearchHistory, false, false),
    );
    await flush();
    expect(container.read(recordSearchHistoryProvider), false);
    sub.close();
  });

  test('失效重建后旧页面请求不能覆盖新页面结果', () async {
    query('old');
    await dispatched(1);
    container.invalidate(provider);
    query('new');
    await dispatched(2);
    requests[1].complete(suggestions(['new']));
    await flush();
    requests[0].complete(suggestions(['old']));
    await flush();
    expect(container.read(provider).suggestions.single.term, 'new');
  });

  test('一个搜索页面释放不影响另一个页面', () async {
    final otherProvider = searchProvider('other');
    final other = container.listen(otherProvider, (_, _) {});
    query('old');
    container.read(otherProvider.notifier).input('other', immediate: true);
    await dispatched(2);
    subscription.close();
    await container.pump();
    requests[0].complete(suggestions(['old']));
    requests[1].complete(suggestions(['other']));
    await flush();
    expect(container.read(otherProvider).suggestions.single.term, 'other');
    other.close();
  });

  test('解析失败时热搜进入失败状态并可重试', () async {
    final sub = container.listen(searchTrendingProvider, (_, _) {});
    await dispatched(1);
    requests[0].complete({'code': 0, 'data': null});
    await flush();
    expect(container.read(searchTrendingProvider), isA<Error>());
    final retry = container.read(searchTrendingProvider.notifier).refresh();
    await dispatched(2);
    requests[1].complete({'code': -1, 'message': 'retry'});
    await retry;
    expect((container.read(searchTrendingProvider) as Error).errMsg, 'retry');
    sub.close();
  });

  testWidgets('完整热搜退出后忽略迟到的滚动回调', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [searchTrendingProvider.overrideWith(_TrendingNotifier.new)],
        child: const GetMaterialApp(home: SearchTrendingPage()),
      ),
    );
    final changed = tester
        .widget<TrendingHeader>(find.byType(TrendingHeader))
        .onScrollRatioChanged;
    await tester.pumpWidget(const SizedBox());
    expect(() => changed(1), returnsNormally);
    Get.reset();
  });

  testWidgets('搜索结果返回后保留输入与分类', (tester) async {
    settings.storedValues[SettingBoxKey.searchSuggestion] = false;
    settings.storedValues[SettingBoxKey.recordSearchHistory] = false;
    final indexes = <int>[];
    await tester.pumpWidget(
      ProviderScope(
        child: GetMaterialApp(
          initialRoute: '/search',
          getPages: [
            GetPage(name: '/search', page: () => const SearchPage()),
            GetPage(
              name: '/searchResult',
              page: () {
                final args = Get.arguments as Map;
                indexes.add(args['initIndex'] as int);
                return Scaffold(
                  body: TextButton(
                    onPressed: () {
                      (args['onIndexChanged'] as void Function(int))(2);
                      Get.back(result: true);
                    },
                    child: const Text('返回'),
                  ),
                );
              },
            ),
          ],
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(EditableText), 'hello');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();
    expect(indexes, [0]);
    await tester.tap(find.text('返回'));
    await tester.pumpAndSettle();
    expect(find.text('hello'), findsOneWidget);
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();
    expect(indexes, [0, 2]);
    await tester.pumpWidget(const SizedBox());
    Get.reset();
  });
}
