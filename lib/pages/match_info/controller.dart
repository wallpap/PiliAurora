import 'package:pili_aurora/http/loading_state.dart';
import 'package:pili_aurora/http/match.dart';
import 'package:pili_aurora/models/remote/match/match_info/contest.dart';
import 'package:pili_aurora/pages/common/dyn/common_dyn_controller.dart';
import 'package:pili_aurora/utils/accounts.dart';
import 'package:get/get.dart';

class MatchInfoController extends CommonDynController {
  MatchInfoController({int? oid})
    : oid = oid ?? int.tryParse(Get.parameters['cid'] ?? '') ?? 0;

  @override
  final int oid;
  @override
  final int replyType = 27;

  @override
  dynamic get sourceId => oid.toString();

  final Rx<LoadingState<MatchContest?>> infoState =
      LoadingState<MatchContest?>.loading().obs;
  int _infoVersion = 0;

  @override
  Object get queryContext => Accounts.main;

  @override
  void onInit() {
    super.onInit();
    getMatchInfo();
  }

  Future<void> getMatchInfo() async {
    if (isClosed) return;
    if (oid <= 0) {
      infoState.value = const Error('赛事标识无效，请重新打开页面');
      loadingState.value = const Error('赛事标识无效，请重新打开页面');
      return;
    }
    final version = ++_infoVersion;
    final account = Accounts.main;
    if (infoState.value is Error) infoState.value = LoadingState.loading();
    bool current() =>
        !isClosed &&
        version == _infoVersion &&
        identical(account, Accounts.main);
    // 评论的来源 ID 已由路由确定，详情失败不应阻塞评论加载。
    final replies = super.onRefresh().catchError((
      Object error,
      StackTrace stackTrace,
    ) {
      if (current()) {
        loadingState.value = Error.fromException(error, stackTrace);
      }
    });
    try {
      final res = await MatchHttp.matchInfo(oid, account: account);
      if (current()) infoState.value = res;
    } catch (error, stackTrace) {
      if (current()) infoState.value = Error.fromException(error, stackTrace);
    }
    await replies;
    if (!isClosed &&
        version == _infoVersion &&
        !identical(account, Accounts.main)) {
      infoState.value = const Error('账号已切换，请刷新赛事信息');
      loadingState.value = const Error('账号已切换，请刷新评论');
    }
  }

  @override
  Future<void> onRefresh() => getMatchInfo();

  @override
  void onClose() {
    _infoVersion++;
    super.onClose();
  }
}
