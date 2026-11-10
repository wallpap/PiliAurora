import 'dart:async' show unawaited;

import 'package:pili_aurora/http/loading_state.dart';
import 'package:pili_aurora/http/reply.dart';
import 'package:pili_aurora/models/remote/emote/package.dart';
import 'package:pili_aurora/models/remote/emote/emote.dart';
import 'package:pili_aurora/pages/common/common_list_controller.dart';
import 'package:pili_aurora/utils/storage.dart';
import 'package:pili_aurora/utils/accounts.dart';
import 'package:pili_aurora/services/logger.dart';
import 'package:pili_aurora/utils/storage_key.dart';
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart';

class RecentEmote {
  const RecentEmote(this.emote, this.width);

  final Emote emote;
  final double? width;

  factory RecentEmote.fromJson(Map<dynamic, dynamic> json) => RecentEmote(
    Emote(text: json['text'] as String?, url: json['url'] as String?),
    (json['width'] as num?)?.toDouble(),
  );

  Map<String, dynamic> toJson() => {
    'text': emote.text,
    'url': emote.url,
    'width': width,
  };
}

class EmotePanelController extends CommonListController<List<Package>?, Package>
    with GetTickerProviderStateMixin {
  TabController? tabController;
  final recentEmotes = <RecentEmote>[].obs;

  @override
  void onInit() {
    super.onInit();
    Accounts.mainChanges.addListener(_onAccountChanged);
    try {
      final history = GStorage.localCache.get(LocalCacheKey.recentEmotes);
      if (history is List) {
        for (final item in history) {
          try {
            final recent = RecentEmote.fromJson(item as Map);
            if (recent.width != null &&
                (!recent.width!.isFinite || recent.width! <= 0)) {
              continue;
            }
            recentEmotes.add(recent);
            if (recentEmotes.length == 40) break;
          } catch (error, stackTrace) {
            logger.w(
              '跳过损坏的历史表情',
              error: error.runtimeType,
              stackTrace: stackTrace,
            );
          }
        }
      }
    } catch (error, stackTrace) {
      logger.w('读取历史表情失败', error: error.runtimeType, stackTrace: stackTrace);
    }
    queryData();
  }

  @override
  Object get queryContext => Accounts.main;

  void _onAccountChanged() {
    tabController?.dispose();
    tabController = null;
    unawaited(onReload());
  }

  Future<void> _historySave = Future.value();

  Future<void> recordEmote(Emote emote, double? width) {
    recentEmotes.removeWhere(
      (item) => item.emote.text == emote.text && item.emote.url == emote.url,
    );
    recentEmotes.insert(0, RecentEmote(emote, width));
    if (recentEmotes.length > 40) recentEmotes.removeLast();
    final history = recentEmotes.map((item) => item.toJson()).toList();
    // 历史记录属于可选缓存，保存失败不影响本次表情选择。
    return _historySave = _historySave.then((_) async {
      try {
        await GStorage.localCache.put(LocalCacheKey.recentEmotes, history);
      } catch (error, stackTrace) {
        logger.w('保存历史表情失败', error: error.runtimeType, stackTrace: stackTrace);
      }
    });
  }

  @override
  bool customHandleResponse(bool isRefresh, Success<List<Package>?> response) {
    final previousIndex = tabController?.index;
    tabController?.dispose();
    tabController = null;
    final packages = response.response;
    if (packages?.isNotEmpty == true) {
      final length = packages!.length + 1;
      final preferredIndex = previousIndex ?? (recentEmotes.isEmpty ? 1 : 0);
      tabController = TabController(
        length: length,
        vsync: this,
        initialIndex: preferredIndex.clamp(0, length - 1).toInt(),
      );
    }
    loadingState.value = response;
    return true;
  }

  @override
  Future<LoadingState<List<Package>?>> customGetData() =>
      ReplyHttp.getEmoteList(account: Accounts.main, business: 'reply');

  @override
  void onClose() {
    Accounts.mainChanges.removeListener(_onAccountChanged);
    tabController?.dispose();
    tabController = null;
    super.onClose();
  }
}
