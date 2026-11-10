import 'package:pili_aurora/http/fav.dart';
import 'package:pili_aurora/http/loading_state.dart';
import 'package:pili_aurora/models/remote/fav/fav_topic/data.dart';
import 'package:pili_aurora/models/remote/fav/fav_topic/topic_item.dart';
import 'package:pili_aurora/pages/fav/account_favorite_controller.dart';
import 'package:pili_aurora/utils/accounts/account.dart';
import 'package:pili_aurora/utils/accounts.dart';

class FavTopicController
    extends AccountFavoriteController<FavTopicData, FavTopicItem> {
  int? total;

  @override
  void checkIsEnd(int length) {
    if (total != null && length >= total!) {
      isEnd = true;
    }
  }

  @override
  List<FavTopicItem>? getDataList(FavTopicData response) {
    total = response.topicList?.pageInfo?.total;
    return response.topicList?.topicItems;
  }

  @override
  Future<void> onRefresh() {
    total = null;
    return super.onRefresh();
  }

  @override
  Future<LoadingState<FavTopicData>> customGetData() =>
      FavHttp.favTopic(account: Accounts.main, page: page);

  @override
  int? itemId(FavTopicItem item) => item.id;

  @override
  Future<LoadingState<void>> removeFavorite(int id, Account account) =>
      FavHttp.delFavTopic(id, account: account);
}
