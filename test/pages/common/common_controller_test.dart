import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:pili_aurora/http/loading_state.dart';
import 'package:pili_aurora/pages/common/common_data_controller.dart';
import 'package:pili_aurora/pages/common/common_list_controller.dart';

class _DataController extends CommonDataController<int, int> {
  final requests = <Completer<LoadingState<int>>>[];
  bool interceptError = false;
  int applied = 0;

  @override
  Future<LoadingState<int>> customGetData() {
    final request = Completer<LoadingState<int>>();
    requests.add(request);
    return request.future;
  }

  @override
  bool customHandleResponse(bool isRefresh, Success<int> response) {
    applied++;
    return false;
  }

  @override
  bool handleError(String? errMsg) => interceptError;
}

class _ListController extends CommonListController<List<int>?, int> {
  final requests = <({int page, Completer<LoadingState<List<int>?>> result})>[];
  final checkedLengths = <int>[];
  int? total;
  bool intercept = false;
  bool failHandling = false;
  bool augment = false;

  @override
  bool? get hasFooter => true;

  @override
  Future<LoadingState<List<int>?>> customGetData() {
    final result = Completer<LoadingState<List<int>?>>();
    requests.add((page: page, result: result));
    return result.future;
  }

  @override
  bool customHandleResponse(bool isRefresh, Success<List<int>?> response) {
    if (failHandling) throw StateError('fixture handler failed');
    if (intercept) loadingState.value = response;
    return intercept;
  }

  @override
  void handleListResponse(List<int> dataList) {
    if (augment) dataList.add(99);
  }

  @override
  void checkIsEnd(int length) {
    checkedLengths.add(length);
    if (total case final total? when length >= total) isEnd = true;
  }
}

void main() {
  late _DataController data;
  late _ListController list;

  setUp(() {
    data = _DataController();
    list = _ListController();
  });
  tearDown(() {
    if (!data.isClosed) data.onDelete();
    if (!list.isClosed) list.onDelete();
  });

  Future<void> seed(List<int> values) async {
    final query = list.onRefresh();
    list.requests.last.result.complete(Success(values));
    await query;
  }

  test(
    'data success uses the typed response and releases the loading flag',
    () async {
      final query = data.queryData();
      expect(data.isLoading, isTrue);
      data.requests.single.complete(const Success(7));
      await query;
      expect(data.loadingState.value.data, 7);
      expect(data.applied, 1);
      expect(data.isLoading, isFalse);
    },
  );

  test('latest refresh wins even if the old response completes last', () async {
    final old = data.onRefresh();
    final current = data.onRefresh();
    data.requests.last.complete(const Success(2));
    await current;
    data.requests.first.complete(const Success(1));
    await old;
    expect(data.loadingState.value.data, 2);
    expect(data.applied, 1);
  });

  test('an old completion cannot release a newer query loading flag', () async {
    final old = data.queryData();
    final current = data.queryData();
    data.requests.first.complete(const Success(1));
    await old;
    expect(data.isLoading, isTrue);
    expect(data.loadingState.value, isA<Loading>());
    data.requests.last.complete(const Success(2));
    await current;
    expect(data.isLoading, isFalse);
  });

  test('stale errors cannot replace the latest success', () async {
    final old = data.queryData();
    final current = data.queryData();
    data.requests.last.complete(const Success(2));
    await current;
    data.requests.first.complete(const Error('old error'));
    await old;
    expect(data.loadingState.value.data, 2);
  });

  test(
    'thrown requests release the loading flag and remain observable',
    () async {
      final query = data.queryData();
      final expectation = expectLater(query, throwsStateError);
      data.requests.single.completeError(StateError('fixture request failed'));
      await expectation;
      expect(data.isLoading, isFalse);
      final retry = data.queryData();
      data.requests.last.complete(const Success(3));
      await retry;
      expect(data.loadingState.value.data, 3);
    },
  );

  test(
    'closed controllers discard responses without invoking business hooks',
    () async {
      final query = data.queryData();
      data.onDelete();
      data.requests.single.complete(const Success(3));
      await query;
      expect(data.applied, 0);
      expect(data.isLoading, isFalse);
      await data.queryData();
      expect(data.requests, hasLength(1));
    },
  );

  test('loading responses are not mistaken for an Error', () async {
    final query = data.queryData();
    data.requests.single.complete(LoadingState<int>.loading());
    await query;
    expect(data.loadingState.value, isA<Loading>());
    expect(data.isLoading, isFalse);
  });

  test('handled errors preserve the state chosen by the caller', () async {
    data.interceptError = true;
    data.loadingState.value = const Success(1);
    final query = data.queryData();
    data.requests.single.complete(const Error('handled'));
    await query;
    expect(data.loadingState.value.data, 1);
  });

  test('unhandled refresh errors become the typed page state', () async {
    final query = data.queryData();
    data.requests.single.complete(const Error('failed', code: 500));
    await query;
    expect(data.loadingState.value, const Error('failed', code: 500));
  });

  test('load more cannot overlap the current data request', () async {
    final query = data.queryData();
    await data.onLoadMore();
    expect(data.requests, hasLength(1));
    data.requests.single.complete(const Success(1));
    await query;
  });

  test('lists own a growable copy of their first page', () async {
    final original = List<int>.unmodifiable([1, 2]);
    await seed(original);
    final next = list.onLoadMore();
    list.requests.last.result.complete(const Success([3]));
    await next;
    expect(list.loadingState.value.data, [1, 2, 3]);
    expect(original, [1, 2]);
    expect(list.requests.map((request) => request.page), [1, 2]);
    expect(list.checkedLengths, [2, 3]);
    expect(list.page, 3);
  });

  test('business list processors receive owned mutable pages', () async {
    list.augment = true;
    final firstPage = List<int>.unmodifiable([1]);
    await seed(firstPage);
    final nextPage = List<int>.unmodifiable([2]);
    final next = list.onLoadMore();
    list.requests.last.result.complete(Success(nextPage));
    await next;
    expect(list.loadingState.value.data, [1, 99, 2, 99]);
    expect(firstPage, [1]);
    expect(nextPage, [2]);
  });

  test('repeated load-more signals issue only one request', () async {
    await seed([1]);
    final next = list.onLoadMore();
    await list.onLoadMore();
    await list.onLoadMore();
    expect(list.requests, hasLength(2));
    list.requests.last.result.complete(const Success([2]));
    await next;
    expect(list.loadingState.value.data, [1, 2]);
  });

  test(
    'refresh invalidates an in-flight append and starts at page one',
    () async {
      await seed([1]);
      final next = list.onLoadMore();
      final refresh = list.onRefresh();
      expect(list.requests.map((request) => request.page), [1, 2, 1]);
      list.requests.last.result.complete(const Success([9]));
      await refresh;
      list.requests[1].result.complete(const Success([2]));
      await next;
      expect(list.loadingState.value.data, [9]);
      expect(list.page, 2);
      expect(list.checkedLengths, [1, 1]);
    },
  );

  test('empty append marks the end and preserves existing entries', () async {
    await seed([1]);
    final next = list.onLoadMore();
    list.requests.last.result.complete(const Success([]));
    await next;
    expect(list.isEnd, isTrue);
    expect(list.page, 2);
    expect(list.loadingState.value.data, [1]);
    await list.onLoadMore();
    expect(list.requests, hasLength(2));
  });

  for (final response in <List<int>?>[null, []]) {
    test('empty first page $response is a valid terminal result', () async {
      final query = list.queryData();
      list.requests.single.result.complete(Success(response));
      await query;
      expect(list.loadingState.value.data, response);
      expect(list.isEnd, isTrue);
      expect(list.page, 1);
    });
  }

  test('load more requires successful first-page data', () async {
    await list.onLoadMore();
    list.loadingState.value = const Error('first page failed');
    await list.onLoadMore();
    expect(list.requests, isEmpty);
  });

  test(
    'a failed append leaves the page retryable without replacing data',
    () async {
      await seed([1]);
      final next = list.onLoadMore();
      list.requests.last.result.complete(const Error('append failed'));
      await next;
      expect(list.loadingState.value.data, [1]);
      expect(list.page, 2);
      expect(list.isLoading, isFalse);
      final retry = list.onLoadMore();
      list.requests.last.result.complete(const Success([2]));
      await retry;
      expect(list.loadingState.value.data, [1, 2]);
      expect(list.requests.map((request) => request.page), [1, 2, 2]);
    },
  );

  test(
    'business hooks still own custom list responses and cursor advancement',
    () async {
      list.intercept = true;
      await seed([4]);
      expect(list.loadingState.value.data, [4]);
      expect(list.page, 2);
      expect(list.checkedLengths, isEmpty);
    },
  );

  test(
    'exceptions in response hooks do not permanently block pagination',
    () async {
      list.failHandling = true;
      final query = list.queryData();
      final expectation = expectLater(query, throwsStateError);
      list.requests.single.result.complete(const Success([1]));
      await expectation;
      expect(list.isLoading, isFalse);
      expect(list.page, 1);
    },
  );

  test(
    'end checks use accumulated length and refresh resets the terminal flag',
    () async {
      list.total = 2;
      await seed([1]);
      final next = list.onLoadMore();
      list.requests.last.result.complete(const Success([2]));
      await next;
      expect(list.isEnd, isTrue);
      final refresh = list.onRefresh();
      expect(list.isEnd, isFalse);
      list.requests.last.result.complete(const Success([9]));
      await refresh;
      expect(list.isEnd, isFalse);
      expect(list.page, 2);
    },
  );

  test(
    'reload publishes Loading before starting the refreshed request',
    () async {
      await seed([1]);
      final reload = list.onReload();
      expect(list.loadingState.value, isA<Loading>());
      expect(list.requests.last.page, 1);
      list.requests.last.result.complete(const Success([2]));
      await reload;
      expect(list.loadingState.value.data, [2]);
    },
  );
}
