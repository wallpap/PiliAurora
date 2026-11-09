import 'package:pili_aurora/http/dynamics.dart';
import 'package:pili_aurora/http/loading_state.dart';
import 'package:pili_aurora/models/remote/dynamic/dyn_reserve_info/data.dart';
import 'package:pili_aurora/utils/utils.dart';
import 'package:pili_aurora/utils/accounts.dart';
import 'package:get/get.dart';

class CreateReserveController extends GetxController {
  CreateReserveController(this.sid);
  final int? sid;
  final _account = Accounts.main;
  final saving = false.obs;
  final loading = false.obs;
  final loadError = Rxn<Error>();
  int _loadGeneration = 0;
  bool get isCurrent => !isClosed && identical(_account, Accounts.main);
  Object get draft => (subType.value, title.value, date.value);
  final RxInt subType = 0.obs;
  String key = Utils.generateRandomString(6);
  final RxString title = ''.obs;
  final now = DateTime.now();
  late final Rx<DateTime> date;
  late final end = now.copyWith(day: now.day + 90);
  final RxBool canCreate = false.obs;

  @override
  void onInit() {
    super.onInit();
    date = DateTime(now.year, now.month, now.day + 1, 20, 0).obs;
    if (sid != null) {
      queryData();
    }
  }

  void updateCanCreate() {
    canCreate.value =
        !loading.value &&
        loadError.value == null &&
        title.value.trim().isNotEmpty;
  }

  Future<void> queryData() async {
    if (!isCurrent || sid == null) return;
    final generation = ++_loadGeneration;
    loading.value = true;
    loadError.value = null;
    canCreate.value = false;
    try {
      final result = await DynamicsHttp.reserveInfo(
        sid: sid,
        account: _account,
      );
      if (!isCurrent || generation != _loadGeneration) return;
      if (result case Success(:final response)) {
        key = Utils.generateRandomString(6);
        title.value = response.title!;
        date.value = DateTime.fromMillisecondsSinceEpoch(
          response.livePlanStartTime! * 1000,
        );
      } else if (result is Error) {
        loadError.value = result;
      }
    } finally {
      if (generation == _loadGeneration) {
        loading.value = false;
        updateCanCreate();
      }
    }
  }

  Future<LoadingState<ReserveInfoData>> onCreate() async {
    if (!isCurrent) return const Error('账号已切换或页面已关闭，请重新打开');
    if (saving.value) return const Error('正在保存预约，请稍候');
    updateCanCreate();
    if (!canCreate.value) return const Error('请填写预约标题');
    final livePlanStartTime = date.value.millisecondsSinceEpoch ~/ 1000;
    if (!date.value.isAfter(DateTime.now())) return const Error('预约时间必须晚于当前时间');
    final title = this.title.value;
    final subType = this.subType.value;
    saving.value = true;
    try {
      final result = sid == null
          ? await DynamicsHttp.createReserve(
              account: _account,
              title: title,
              subType: subType,
              livePlanStartTime: livePlanStartTime,
            )
          : await DynamicsHttp.updateReserve(
              account: _account,
              sid: sid!,
              subType: subType,
              title: title,
              livePlanStartTime: livePlanStartTime,
            );
      if (!isCurrent) return const Error('账号已切换或页面已关闭');
      if (result case Success(:final response)) {
        return Success(
          ReserveInfoData(
            id: response,
            title: title,
            livePlanStartTime: livePlanStartTime,
          ),
        );
      }
      return result as Error;
    } finally {
      saving.value = false;
    }
  }

  @override
  void onClose() {
    _loadGeneration++;
    super.onClose();
  }
}
