import 'package:pili_aurora/grpc/bilibili/main/community/reply/v1.pb.dart'
    show ReplyInfo, DetailListReply, Mode;
import 'package:pili_aurora/grpc/reply.dart';
import 'package:pili_aurora/http/loading_state.dart';
import 'package:pili_aurora/pages/common/reply_controller.dart';
import 'package:pili_aurora/utils/id_utils.dart';
import 'package:pili_aurora/utils/storage_pref.dart';
import 'package:extended_nested_scroll_view/extended_nested_scroll_view.dart';
import 'package:fixnum/fixnum.dart';
import 'package:flutter/scheduler.dart';
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart';
import 'package:super_sliver_list/super_sliver_list.dart';

class VideoReplyReplyController extends ReplyController
    with GetSingleTickerProviderStateMixin {
  VideoReplyReplyController({
    required this.id,
    required this.oid,
    required this.rpid,
    required this.dialog,
    required this.replyType,
  });
  final int? dialog;
  int? id;
  // 视频aid 请求时使用的oid
  int oid;
  // rpid 请求楼中楼回复
  int rpid;
  int replyType;

  final firstFloor = Rxn<ReplyInfo>();

  final index = RxnInt();

  final listController = ListController();

  AnimationController? _controller;
  AnimationController get animController => _controller ??= AnimationController(
    duration: const Duration(milliseconds: 1000),
    vsync: this,
  );

  late final horizontalPreview = Pref.horizontalPreview;

  @override
  dynamic get sourceId => replyType == 1 ? IdUtils.av2bv(oid) : oid;

  @override
  void onInit() {
    super.onInit();
    final cacheSortType = Pref.reply2SortType;
    sortType.value = cacheSortType;
    mode = cacheSortType == .time ? Mode.MAIN_LIST_TIME : Mode.MAIN_LIST_HOT;
    queryData();
  }

  @override
  List<ReplyInfo>? getDataList(response) {
    return dialog != null ? response.replies : response.root.replies;
  }

  @override
  bool customHandleResponse(bool isRefresh, Success response) {
    final data = response.response;

    subjectControl = data.subjectControl;
    upMid ??= data.subjectControl.upMid;
    paginationReply = data.paginationReply;
    isEnd = data.cursor.isEnd;

    // reply2Reply // isDialogue.not
    if (data is DetailListReply) {
      count.value = data.root.count.toInt();
      if (isRefresh) {
        firstFloor.value = data.root;
      }
    }

    return false;
  }

  @override
  List<ReplyInfo> filterList(List<ReplyInfo> source, bool isRefresh) {
    final filtered = super.filterList(source, isRefresh);
    if (id != null) {
      setIndexById(Int64(id!), filtered);
      id = null;
    }
    return filtered;
  }

  bool setIndexById(Int64 id64, [List<ReplyInfo>? replies]) {
    final index = (replies ?? loadingState.value.data!).indexWhere(
      (item) => item.id == id64,
    );
    if (index != -1) {
      this.index.value = index;
      jumpToItem(index);
      return true;
    }
    return false;
  }

  ExtendedNestedScrollController? nestedController;

  @pragma('vm:notify-debugger-on-exception')
  void jumpToItem(int index) {
    SchedulerBinding.instance.addPostFrameCallback((_) {
      if (isClosed) return;
      animController.forward(from: 0);
      try {
        // ignore: invalid_use_of_visible_for_testing_member
        final offset = listController.getOffsetToReveal(index, 0.25);
        if (offset.isFinite) {
          if (nestedController case final nestedController?) {
            nestedController.nestedPositions.last.localJumpTo(offset);
          } else {
            scrollController.jumpTo(offset);
          }
        }
      } catch (_) {}
    });
  }

  @override
  Future<LoadingState> customGetData() => dialog != null
      ? ReplyGrpc.dialogList(
          type: replyType,
          oid: oid,
          root: rpid,
          dialog: dialog!,
          offset: paginationReply?.nextOffset,
        )
      : ReplyGrpc.detailList(
          type: replyType,
          oid: oid,
          root: rpid,
          rpid: id ?? 0,
          mode: mode,
          offset: paginationReply?.nextOffset,
        );

  @override
  void onAccountChanged() {
    firstFloor.value = null;
    super.onAccountChanged();
  }

  @override
  Future<void> onReload() {
    if (loadingState.value.isSuccess) {
      index.value = null;
    }
    return super.onReload();
  }

  @override
  void onReplyPublished(ReplyInfo? replyInfo, {ReplyInfo? parent}) {
    if (isClosed) return;
    final list = loadingState.value.dataOrNull;
    if (replyInfo == null || parent == null || list == null || isLoading) {
      onReload();
      return;
    }
    if (list.any((reply) => reply.id == replyInfo.id)) return;
    final parentIndex = list.indexWhere((reply) => reply.id == parent.id);
    final isRoot = parent.id.toInt() == rpid;
    if (parentIndex < 0 && !isRoot) {
      onReload();
      return;
    }
    list.insert(parentIndex + 1, replyInfo);
    if (count.value >= 0) count.value++;
    loadingState.refresh();
  }

  @override
  void onClose() {
    _controller?.dispose();
    _controller = null;
    super.onClose();
  }
}
