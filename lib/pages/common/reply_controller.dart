import 'package:collection/collection.dart' show IterableExtension;
import 'package:pili_aurora/common/widgets/flutter/text_field/controller.dart';
import 'package:pili_aurora/grpc/bilibili/main/community/reply/v1.pb.dart'
    show MainListReply, ReplyInfo, SubjectControl, Mode;
import 'package:pili_aurora/grpc/bilibili/pagination.pb.dart';
import 'package:pili_aurora/http/loading_state.dart';
import 'package:pili_aurora/http/reply.dart';
import 'package:pili_aurora/models/common/reply/reply_sort_type.dart';
import 'package:pili_aurora/pages/common/common_list_controller.dart';
import 'package:pili_aurora/pages/common/publish/publish_route.dart';
import 'package:pili_aurora/pages/video/reply_new/view.dart';
import 'package:pili_aurora/utils/accounts.dart';
import 'package:pili_aurora/utils/feed_back.dart';
import 'package:pili_aurora/utils/reply_utils.dart';
import 'package:pili_aurora/utils/reply_filter.dart';
import 'package:pili_aurora/utils/storage_pref.dart';
import 'package:fixnum/fixnum.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart';

abstract class ReplyController<R> extends CommonListController<R, ReplyInfo> {
  ReplyController({int count = -1}) : count = RxInt(count);

  late final RxInt count;

  late final Rx<ReplySortType> sortType;
  late Mode mode;

  final savedReplies = <Object, List<RichTextItem>?>{};

  Int64? upMid;
  Int64? cursorNext;
  SubjectControl? subjectControl;
  FeedPaginationReply? paginationReply;
  late bool hasUpTop = false;
  bool _togglingTop = false;

  @override
  bool? get hasFooter => true;

  @override
  bool get refillFilteredPages => Pref.minimumReplyUserLevel > 0;

  @override
  List<ReplyInfo> filterList(List<ReplyInfo> source, bool isRefresh) {
    final top = isRefresh && hasUpTop ? source.firstOrNull : null;
    filterRepliesByLevel(source, Pref.minimumReplyUserLevel);
    if (top != null) {
      hasUpTop = source.isNotEmpty && identical(source.first, top);
    }
    return source;
  }

  String get emptyReplyMessage => refillFilteredPages ? '暂无符合等级条件的评论' : '还没有评论';

  // comment antifraud
  late final _enableCommAntifraud = Pref.enableCommAntifraud;
  late final _biliSendCommAntifraud = Pref.biliSendCommAntifraud;
  bool get enableCommAntifraud =>
      _enableCommAntifraud || _biliSendCommAntifraud;
  dynamic get sourceId;

  @override
  void onInit() {
    super.onInit();
    final cacheSortType = Pref.replySortType;
    sortType = cacheSortType.obs;
    mode = cacheSortType == .time ? Mode.MAIN_LIST_TIME : Mode.MAIN_LIST_HOT;
    Accounts.mainChanges.addListener(onAccountChanged);
  }

  @override
  Object get queryContext => Accounts.main;

  void onAccountChanged() {
    savedReplies.clear();
    count.value = -1;
    upMid = null;
    hasUpTop = false;
    onReload();
  }

  @override
  void checkIsEnd(int length) {
    // 过滤后可见条数与总数不同，且置顶项可能重复；以响应游标为准。
    if (refillFilteredPages) return;
    final count = this.count.value;
    if (count != -1 && length >= count) {
      isEnd = true;
    }
  }

  @override
  bool customHandleResponse(bool isRefresh, Success<R> response) {
    final data = response.response as MainListReply;
    cursorNext = data.cursor.next;
    paginationReply = data.paginationReply;
    count.value = data.subjectControl.count.toInt();
    if (isRefresh) {
      subjectControl = data.subjectControl;
      upMid = data.subjectControl.upMid;
      if (hasUpTop = data.hasUpTop()) {
        data.replies.insert(0, data.upTop);
      }
      if (subjectControl?.title == ReplySortType.select.desc) {
        sortType.value = .select;
      }
    }
    _deduplicateReplies(data, isRefresh: isRefresh);
    isEnd = data.cursor.isEnd;
    return false;
  }

  void _deduplicateReplies(MainListReply data, {required bool isRefresh}) {
    final seen = <Int64>{};
    if (!isRefresh) {
      seen.addAll(
        loadingState.value.dataOrNull?.map((reply) => reply.id) ?? [],
      );
    }
    data.replies.removeWhere((reply) => !seen.add(reply.id));
  }

  @override
  Future<void> onRefresh() {
    cursorNext = null;
    subjectControl = null;
    paginationReply = null;
    return super.onRefresh();
  }

  // 排序搜索评论
  void queryBySort() {
    if (isLoading) return;
    switch (sortType.value) {
      case ReplySortType.time:
        sortType.value = ReplySortType.hot;
        mode = Mode.MAIN_LIST_HOT;
        break;
      case ReplySortType.hot:
        sortType.value = ReplySortType.time;
        mode = Mode.MAIN_LIST_TIME;
        break;
      case ReplySortType.select:
        return;
    }
    feedBack();
    onReload();
  }

  (bool inputDisable, String? hint) get replyHint {
    String? hint;
    bool inputDisable = false;
    try {
      if (subjectControl case final subjectControl?) {
        inputDisable = subjectControl.inputDisable;
        if (subjectControl.hasRootText()) {
          final rootText = subjectControl.rootText;
          if (inputDisable) {
            SmartDialog.showToast(rootText);
          }
          if (rootText.contains('可发') || rootText.contains('可见')) {
            hint = rootText;
          }
        }
      }
    } catch (_) {}
    return (inputDisable, hint);
  }

  void onReply(
    ReplyInfo? replyItem, {
    int? oid,
    int? replyType,
    int? index,
  }) {
    if (isClosed) return;
    if (loadingState.value case Error(:final errMsg, :final code)) {
      if (errMsg != null && (code == 12061 || code == 12002)) {
        SmartDialog.showToast(errMsg);
        return;
      }
    }

    assert(replyItem != null || (oid != null && replyType != null));

    final (bool inputDisable, String? hint) = replyHint;
    if (inputDisable) {
      return;
    }

    final account = Accounts.main;
    final source = sourceId;
    final targetOid = oid ?? replyItem!.oid.toInt();
    final type = replyItem?.type.toInt() ?? replyType!;
    final root = oid != null
        ? 0
        : replyItem!.root != Int64.ZERO
        ? replyItem.root.toInt()
        : replyItem.id.toInt();
    final parent = oid != null ? 0 : replyItem!.id.toInt();
    final key = (oid: targetOid, type: type, root: root, parent: parent);
    bool isCurrent() =>
        !isClosed && identical(account, Accounts.main) && source == sourceId;
    Get.key.currentState!.push(
      PublishRoute(
        pageBuilder: (buildContext, animation, secondaryAnimation) {
          return ReplyPage(
            hint: hint,
            oid: targetOid,
            root: root,
            parent: parent,
            replyType: type,
            replyItem: replyItem,
            items: savedReplies[key],

            /// hd api deprecated
            // canUploadPic: canUploadPic,
            onSave: (reply) {
              if (!isCurrent()) return;
              if (reply.isEmpty) {
                savedReplies.remove(key);
              } else {
                savedReplies[key] = reply.toList();
              }
            },
            onSuccess: (replyInfo) {
              if (!isCurrent()) return;
              savedReplies.remove(key);
              onReplyPublished(replyInfo, parent: replyItem);
              if (replyInfo != null && enableCommAntifraud) {
                onCheckReply(replyInfo, isManual: false);
              }
            },
          );
        },
        settings: RouteSettings(arguments: Get.arguments),
      ),
    );
  }

  void onReplyPublished(ReplyInfo? replyInfo, {ReplyInfo? parent}) {
    final list = loadingState.value.dataOrNull;
    if (isClosed) return;
    if (replyInfo == null || list == null || isLoading) {
      onReload();
      return;
    }
    if (parent == null) {
      if (list.any((reply) => reply.id == replyInfo.id)) return;
      list.insert(hasUpTop && list.isNotEmpty ? 1 : 0, replyInfo);
    } else {
      final current = list.firstWhereOrNull((reply) => reply.id == parent.id);
      if (current == null) {
        onReload();
        return;
      }
      if (current.replies.any((reply) => reply.id == replyInfo.id)) return;
      current
        ..count += 1
        ..replies.add(replyInfo);
    }
    if (count.value >= 0) count.value++;
    loadingState.refresh();
  }

  void onRemove(int index, ReplyInfo item, int? subIndex) {
    if (isClosed || isLoading) return;
    final list = loadingState.value.dataOrNull;
    final currentIndex = list?.indexWhere((reply) => reply.id == item.id) ?? -1;
    if (list == null || currentIndex < 0) return;
    if (subIndex == null) {
      list.removeAt(currentIndex);
      hasUpTop = list.any((reply) => reply.replyControl.isUpTop);
    } else {
      if (!identical(item, list[currentIndex]) ||
          subIndex < 0 ||
          subIndex >= item.replies.length) {
        return;
      }
      item.replies.removeAt(subIndex);
      if (item.count > 0) item.count -= 1;
    }
    if (count.value > 0) count.value--;
    loadingState.refresh();
  }

  void onCheckReply(ReplyInfo replyInfo, {bool isManual = true}) {
    ReplyUtils.onCheckReply(
      replyInfo: replyInfo,
      biliSendCommAntifraud: _biliSendCommAntifraud,
      sourceId: sourceId,
      isManual: isManual,
    );
  }

  Future<void> onToggleTop(
    ReplyInfo item,
    int index,
    oid,
    int type,
  ) async {
    final list = loadingState.value.dataOrNull;
    if (_togglingTop || list == null) return;
    _togglingTop = true;
    final account = Accounts.main;
    bool isUpTop = item.replyControl.isUpTop;
    try {
      final res = await ReplyHttp.replyTop(
        account: account,
        oid: oid,
        type: type,
        rpid: item.id,
        isUpTop: isUpTop,
      );
      if (isClosed ||
          !identical(account, Accounts.main) ||
          !identical(list, loadingState.value.dataOrNull)) {
        return;
      }
      final currentIndex = list.indexWhere((reply) => reply.id == item.id);
      if (currentIndex < 0) return;
      item = list[currentIndex];
      if (res.isSuccess) {
        item.ensureReplyControl().isUpTop = !isUpTop;
        hasUpTop = !isUpTop;
        if (!isUpTop && currentIndex != 0) {
          list
            ..first.ensureReplyControl().isUpTop = false
            ..insert(0, list.removeAt(currentIndex));
        }
        loadingState.refresh();
        SmartDialog.showToast('${isUpTop ? '取消' : ''}置顶成功');
      } else {
        res.toast();
      }
    } finally {
      _togglingTop = false;
    }
  }

  @override
  void onClose() {
    Accounts.mainChanges.removeListener(onAccountChanged);
    savedReplies.clear();
    super.onClose();
  }
}
