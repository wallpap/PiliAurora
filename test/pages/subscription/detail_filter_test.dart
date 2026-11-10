import 'dart:io';
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:pili_aurora/http/loading_state.dart';
import 'package:pili_aurora/http/init.dart';
import 'package:pili_aurora/models/remote/sub/sub/list.dart';
import 'package:pili_aurora/models/remote/sub/sub_detail/data.dart';
import 'package:pili_aurora/models/remote/sub/sub_detail/media.dart';
import 'package:pili_aurora/pages/subscription/hidden_media.dart';
import 'package:pili_aurora/pages/subscription_detail/controller.dart';
import 'package:pili_aurora/utils/accounts.dart';
import 'package:pili_aurora/utils/accounts/account.dart';
import 'package:pili_aurora/models/common/account_type.dart';
import 'package:pili_aurora/utils/storage.dart';
import 'package:pili_aurora/utils/storage_key.dart';

class _DetailController extends SubDetailController {
  final requests = <int>[];
  bool failSecondPage = false;
  int total = 21;
  Completer<void>? pending;

  _DetailController() {
    id = 1;
  }

  @override
  Future<LoadingState<SubDetailData>> customGetData() async {
    final requestedPage = page;
    requests.add(requestedPage);
    if (pending != null) await pending!.future;
    if (page == 2 && failSecondPage) return const Error('网络错误');
    return Success(
      SubDetailData(
        info: SubItemModel(id: 1, type: 21, mediaCount: total),
        medias: [
          for (
            var id = (requestedPage - 1) * 20 + 1;
            id <= requestedPage * 20 && id <= total;
            id++
          )
            SubDetailItemModel(id: id, title: 'video $id'),
        ],
      ),
    );
  }
}

void main() {
  late Directory directory;
  late _DetailController controller;

  setUpAll(() async {
    directory = await Directory.systemTemp.createTemp(
      'subscription_detail_test',
    );
    Hive.init(directory.path);
    GStorage.setting = await Hive.openBox('setting');
    GStorage.video = await Hive.openBox('video');
    GStorage.localCache = await Hive.openBox('localCache');
  });
  tearDownAll(() async {
    await Hive.close();
    await directory.delete(recursive: true);
  });
  setUp(() async {
    await GStorage.localCache.clear();
    await GStorage.setting.put(
      SettingBoxKey.hideInvalidSubscriptionVideos,
      true,
    );
    await HiddenSubscriptionMedia(GStorage.localCache, Accounts.main.mid).add(
      21,
      1,
      {for (var id = 1; id <= 20; id++) (id, 2)},
    );
    controller = _DetailController();
  });
  tearDown(() => controller.onDelete());

  test(
    'an entirely hidden first page still loads valid videos from later pages',
    () async {
      await controller.queryData();
      expect(controller.requests, [1, 2]);
      expect(controller.loadingState.value.data!.map((item) => item.id), [21]);
      expect(controller.isEnd, true);
    },
  );

  test(
    'failed continuation stops instead of repeatedly requesting the same page',
    () async {
      controller.failSecondPage = true;
      await controller.queryData();
      expect(controller.requests, [1, 2]);
      expect(controller.loadingState.value.data, isEmpty);
      expect(controller.isEnd, false);
    },
  );

  test(
    'disabling the setting and refreshing restores locally hidden content',
    () async {
      await controller.queryData();
      await GStorage.setting.put(
        SettingBoxKey.hideInvalidSubscriptionVideos,
        false,
      );
      await controller.onRefresh();
      expect(
        controller.loadingState.value.data!.map((item) => item.id),
        List.generate(20, (index) => index + 1),
      );
      expect(controller.isEnd, false);
    },
  );
  test('连续隐藏页单次最多补读五页，仍可显式继续分页', () async {
    controller.total = 200;
    await HiddenSubscriptionMedia(GStorage.localCache, Accounts.main.mid).add(
      21,
      1,
      {for (var id = 1; id <= 120; id++) (id, 2)},
    );
    await controller.queryData();
    expect(controller.requests, [1, 2, 3, 4, 5]);
    expect(controller.loadingState.value.data, isEmpty);
    expect(controller.isEnd, isFalse);
    await controller.onLoadMore();
    expect(controller.requests, [1, 2, 3, 4, 5, 6, 7]);
    expect(controller.loadingState.value.data!.first.id, 121);
  });

  test('切号后的迟到详情不使用新账号隐藏记录或继续补页', () async {
    final original = Accounts.main;
    controller.pending = Completer<void>();
    final query = controller.queryData();
    Accounts.accountMode[AccountType.main.index] = LoginAccount(
      BiliCookieJar.fromJson({'DedeUserID': '9'}),
      null,
      null,
    );
    controller.pending!.complete();
    try {
      await query;
      expect(controller.loadingState.value, isA<Loading>());
      expect(controller.requests, [1]);
      expect(controller.subInfo, isNull);
    } finally {
      Accounts.accountMode[AccountType.main.index] = original;
    }
  });
}
