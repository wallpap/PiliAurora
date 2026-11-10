import 'package:pili_aurora/http/fav.dart';
import 'package:pili_aurora/http/loading_state.dart';
import 'package:pili_aurora/http/member_favorites.dart';
import 'package:pili_aurora/utils/accounts.dart';
import 'package:pili_aurora/models/remote/space/space_fav/data.dart';
import 'package:pili_aurora/models/remote/space/space_fav/list.dart';
import 'package:pili_aurora/pages/common/common_data_controller.dart';
import 'package:get/get.dart';

class MemberFavoriteCtr
    extends CommonDataController<List<SpaceFavData>?, List<SpaceFavData>?> {
  MemberFavoriteCtr({
    required this.mid,
  });

  final int mid;
  int _folderGeneration = 0;
  Object? _favLoad;
  Object? _subLoad;
  bool _foldersReady = true;

  @override
  Object get queryContext => Accounts.main;

  void _onAccountChanged() => onReload();

  @override
  Future<void> queryData([bool isRefresh = true]) {
    if (isRefresh) {
      _folderGeneration++;
      _favLoad = _subLoad = null;
      _foldersReady = false;
      favPage = subPage = 2;
    }
    return super.queryData(isRefresh);
  }

  @override
  void onClose() {
    _folderGeneration++;
    _foldersReady = false;
    Accounts.mainChanges.removeListener(_onAccountChanged);
    super.onClose();
  }

  late int favPage = 2;
  bool _favExpand = true;
  final RxBool favEnd = true.obs;
  final Rx<SpaceFavData> favState = SpaceFavData().obs;

  late int subPage = 2;
  bool _subExpand = true;
  final RxBool subEnd = true.obs;
  final Rx<SpaceFavData> subState = SpaceFavData().obs;

  bool isExpand(bool isFav) {
    return isFav ? _favExpand : _subExpand;
  }

  void setExpand(bool isFav) {
    if (isFav) {
      flag = _favExpand;
      _favExpand = !_favExpand;
    } else {
      _subExpand = !_subExpand;
    }
  }

  bool flag = false;

  @override
  void onInit() {
    super.onInit();
    Accounts.mainChanges.addListener(_onAccountChanged);
    queryData();
  }

  @override
  Future<void> onRefresh() {
    favPage = 2;
    subPage = 2;
    return super.onRefresh();
  }

  @override
  bool customHandleResponse(
    bool isRefresh,
    Success<List<SpaceFavData>?> response,
  ) {
    final rows = response.response;
    // 空列表是正常无收藏；非空响应必须同时具备收藏和订阅两个分区。
    if (rows == null || rows.isEmpty) {
      _foldersReady = false;
      loadingState.value = response;
      return true;
    }
    if (rows.length < 2 ||
        rows
            .take(2)
            .any(
              (row) =>
                  row.mediaListResponse == null ||
                  (row.mediaListResponse!.count ?? -1) < 0 ||
                  (row.mediaListResponse!.list == null &&
                      row.mediaListResponse!.count! > 0),
            )) {
      _foldersReady = false;
      loadingState.value = const Error('收藏分区响应不完整，请重试');
      return true;
    }
    _foldersReady = true;
    favState.value = rows.first;
    subState.value = rows[1];
    favEnd.value =
        rows.first.mediaListResponse!.count! <=
        (rows.first.mediaListResponse!.list?.length ?? 0);
    subEnd.value =
        rows[1].mediaListResponse!.count! <=
        (rows[1].mediaListResponse!.list?.length ?? 0);
    loadingState.value = response;
    return true;
  }

  void Function(bool?) folderDeletionAction(
    bool subscribed,
    SpaceFavItemModel item,
  ) {
    final account = Accounts.main;
    final generation = _folderGeneration;
    final state = subscribed ? subState : favState;
    final snapshot = state.value;
    return (deleted) {
      if (deleted != true ||
          isClosed ||
          isLoading ||
          generation != _folderGeneration ||
          !identical(account, Accounts.main) ||
          !identical(snapshot, state.value)) {
        return;
      }
      snapshot.mediaListResponse?.list?.remove(item);
      state.refresh();
      // 远端删除改变偏移边界，刷新而不是沿旧页码继续加载。
      onRefresh();
    };
  }

  Future<void> userFavFolder() => _loadFolders(false);
  Future<void> userSubFolder() => _loadFolders(true);

  Future<void> _loadFolders(bool subscribed) async {
    final state = subscribed ? subState : favState;
    final end = subscribed ? subEnd : favEnd;
    if (isClosed ||
        !_foldersReady ||
        (subscribed ? _subLoad : _favLoad) != null ||
        end.value) {
      return;
    }
    final operation = Object();
    if (subscribed) {
      _subLoad = operation;
    } else {
      _favLoad = operation;
    }
    final account = Accounts.main;
    final generation = _folderGeneration;
    final snapshot = state.value;
    try {
      final result = await MemberFavoritesHttp.folders(
        account: account,
        mid: mid,
        page: subscribed ? subPage : favPage,
        subscribed: subscribed,
      );
      if (isClosed ||
          generation != _folderGeneration ||
          !identical(account, Accounts.main) ||
          !identical(snapshot, state.value)) {
        return;
      }
      if (result case Success(:final response)) {
        final list = snapshot.mediaListResponse!.list ??= [];
        final ids = list.map((item) => item.id).toSet();
        list.addAll(response.items.where((item) => ids.add(item.id)));
        end.value = !response.hasMore || response.items.isEmpty;
        if (subscribed) {
          subPage++;
        } else {
          favPage++;
        }
        state.refresh();
      } else {
        result.toast();
      }
    } finally {
      if (subscribed) {
        if (identical(_subLoad, operation)) _subLoad = null;
      } else {
        if (identical(_favLoad, operation)) _favLoad = null;
      }
    }
  }

  @override
  Future<LoadingState<List<SpaceFavData>?>> customGetData() =>
      FavHttp.spaceFav(mid: mid, account: Accounts.main);
}
