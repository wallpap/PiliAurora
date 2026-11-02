import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:hive_ce/hive.dart';
import 'package:pili_aurora/http/init.dart';
import 'package:pili_aurora/pages/search/controller.dart';
import 'package:pili_aurora/utils/storage.dart';
import 'package:pili_aurora/utils/storage_key.dart';

class _Box<T> implements Box<T> {
  final storedValues = <dynamic, T>{};
  @override
  T? get(dynamic key, {T? defaultValue}) => storedValues[key] ?? defaultValue;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final requests = <Completer<Map<String, dynamic>>>[];
  final settings = _Box<dynamic>();
  late SSearchController controller;
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
  Future<void> query(String text) {
    controller.controller.text = text;
    return controller.onValueChanged(text);
  }

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
    Get.testMode = true;
  });
  setUp(() {
    requests.clear();
    settings.storedValues[SettingBoxKey.searchSuggestion] = true;
    controller = Get.put(SSearchController('fixture'));
  });
  tearDown(Get.reset);
  tearDownAll(() => Request.dio.close(force: true));

  test('联想请求乱序返回时保留最新输入的结果，空结果清除旧建议', () async {
    final old = query('old');
    await dispatched(1);
    final latest = query('latest');
    await dispatched(2);
    requests[1].complete(suggestions(['latest-result']));
    await latest;
    requests[0].complete(suggestions(['old-result']));
    await old;
    expect(controller.searchSuggestList.single.term, 'latest-result');
    final empty = query('none');
    await dispatched(3);
    requests[2].complete(suggestions([]));
    await empty;
    expect(controller.searchSuggestList, isEmpty);
  });

  test('清空后重新输入相同词时，防抖开始前旧结果仍应失效', () async {
    final old = query('same');
    await dispatched(1);
    controller.controller.clear();
    controller.onChange('');
    controller.controller.text = 'same';
    controller.onChange('same');
    requests.single.complete(suggestions(['old-result']));
    await old;
    expect(controller.searchSuggestList, isEmpty);
  });

  test('禁用搜索建议时不发起查询，也不访问未初始化的列表', () async {
    Get
      ..delete<SSearchController>()
      ..delete<BaseSearchController>();
    settings.storedValues[SettingBoxKey.searchSuggestion] = false;
    controller = Get.put(SSearchController('disabled'));
    await query('disabled');
    expect(requests, isEmpty);
  });

  test('关闭页面后忽略迟到的建议，不再发起新请求', () async {
    final pending = query('old');
    await dispatched(1);
    controller.onDelete();
    requests.single.complete(suggestions(['late-result']));
    await pending;
    await controller.onValueChanged('new');
    expect(controller.searchSuggestList, isEmpty);
    expect(requests, hasLength(1));
  });
}
