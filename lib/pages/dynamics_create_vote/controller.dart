import 'package:pili_aurora/http/dynamics.dart';
import 'package:pili_aurora/http/loading_state.dart';
import 'package:pili_aurora/http/msg.dart';
import 'package:pili_aurora/models/dynamics/vote_model.dart';
import 'package:pili_aurora/utils/accounts.dart';
import 'package:pili_aurora/utils/utils.dart';
import 'package:get/get.dart';

class CreateVoteController extends GetxController {
  CreateVoteController(this.voteId);
  final int? voteId;
  final _account = Accounts.main;
  final saving = false.obs;
  final loading = false.obs;
  final loadError = Rxn<Error>();
  int _loadGeneration = 0;
  final _uploads = <Option, int>{};

  bool get isCurrent => !isClosed && identical(_account, Accounts.main);
  List<Object?> get draft => [
    title.value,
    desc.value,
    type.value,
    choiceCnt.value,
    endtime.value,
    for (final option in options) (option.optDesc, option.imgUrl),
  ];

  String key = Utils.generateRandomString(6);
  final RxString title = ''.obs;
  final RxString desc = ''.obs;
  final RxInt type = 0.obs;
  final RxList<Option> options = <Option>[
    Option(optDesc: '', imgUrl: ''),
    Option(optDesc: '', imgUrl: ''),
  ].obs;
  final RxInt choiceCnt = 1.obs;
  final now = DateTime.now();
  late final end = now.copyWith(day: now.day + 90);
  late Rx<DateTime> endtime;
  final RxBool canCreate = false.obs;

  void updateCanCreate() {
    if (loading.value || loadError.value != null) {
      canCreate.value = false;
      return;
    }
    if (type.value == 0) {
      canCreate.value =
          title.value.isNotEmpty &&
          options.every((e) => e.optDesc?.isNotEmpty == true);
    } else {
      canCreate.value =
          title.value.isNotEmpty &&
          options.every(
            (e) =>
                e.optDesc?.isNotEmpty == true && e.imgUrl?.isNotEmpty == true,
          );
    }
  }

  @override
  void onInit() {
    super.onInit();
    endtime = DateTime(
      now.year,
      now.month,
      now.day + 1,
      now.hour,
      now.minute,
    ).obs;
    if (voteId != null) {
      queryData();
    }
  }

  Future<void> queryData() async {
    if (!isCurrent || voteId == null) return;
    final generation = ++_loadGeneration;
    loading.value = true;
    loadError.value = null;
    canCreate.value = false;
    try {
      final result = await DynamicsHttp.voteInfo(voteId, account: _account);
      if (!isCurrent || generation != _loadGeneration) return;
      if (result case Success(:final response)) {
        key = Utils.generateRandomString(6);
        title.value = response.title!;
        desc.value = response.desc ?? '';
        type.value =
            response.type ??
            (response.options.first.imgUrl?.isNotEmpty == true ? 1 : 0);
        options.value = response.options
            .map(
              (option) =>
                  Option(optDesc: option.optDesc, imgUrl: option.imgUrl),
            )
            .toList();
        choiceCnt.value = response.choiceCnt!;
        endtime.value = DateTime.fromMillisecondsSinceEpoch(
          response.endTime! * 1000,
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

  void onDel(int i) {
    options.removeAt(i);
    updateCanCreate();
    if (choiceCnt.value > options.length) {
      choiceCnt.value = options.length;
    }
  }

  Future<LoadingState<VoteInfo>> onCreate() async {
    if (!isCurrent) return const Error('账号已切换或页面已关闭，请重新打开');
    if (saving.value) return const Error('正在保存投票，请稍候');
    updateCanCreate();
    if (!canCreate.value ||
        options.length < 2 ||
        choiceCnt.value < 1 ||
        choiceCnt.value > options.length) {
      return const Error('请填写完整的投票内容');
    }
    final duration = endtime.value.difference(DateTime.now()).inSeconds;
    if (duration < 300) return const Error('截止时间至少需要五分钟');
    final voteInfo = VoteInfo(
      title: title.value,
      desc: desc.value,
      type: type.value,
      duration: duration,
      options: options
          .map(
            (option) => Option(optDesc: option.optDesc, imgUrl: option.imgUrl),
          )
          .toList(),
      onlyFansLevel: 0,
      choiceCnt: choiceCnt.value,
      votePublisher: _account.mid,
      voteId: voteId,
    );
    saving.value = true;
    try {
      final result = await (voteId == null
          ? DynamicsHttp.createVote(voteInfo, account: _account)
          : DynamicsHttp.updateVote(voteInfo, account: _account));
      if (!isCurrent) return const Error('账号已切换或页面已关闭');
      if (result case Success(:final response)) {
        voteInfo.voteId = response;
        return Success(voteInfo);
      }
      return result as Error;
    } finally {
      saving.value = false;
    }
  }

  Future<void> onUpload(Option option, String path) async {
    if (!isCurrent || !options.contains(option)) return;
    final generation = (_uploads[option] ?? 0) + 1;
    _uploads[option] = generation;
    try {
      final result = await MsgHttp.uploadBfs(
        account: _account,
        path: path,
        category: 'daily',
        biz: 'vote',
      );
      if (!isCurrent ||
          !options.contains(option) ||
          _uploads[option] != generation) {
        return;
      }
      if (result case Success(:final response)) {
        option.imgUrl = response.imageUrl;
        options.refresh();
        updateCanCreate();
      } else {
        result.toast();
      }
    } finally {
      if (_uploads[option] == generation) _uploads.remove(option);
    }
  }

  @override
  void onClose() {
    _loadGeneration++;
    _uploads.clear();
    super.onClose();
  }
}
