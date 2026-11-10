import 'package:pili_aurora/http/fav.dart';
import 'package:pili_aurora/http/loading_state.dart';
import 'package:pili_aurora/models/remote/space/space_cheese/data.dart';
import 'package:pili_aurora/models/remote/space/space_cheese/item.dart';
import 'package:pili_aurora/pages/fav/account_favorite_controller.dart';
import 'package:pili_aurora/utils/accounts.dart';
import 'package:pili_aurora/utils/accounts/account.dart';

class FavCheeseController
    extends AccountFavoriteController<SpaceCheeseData, SpaceCheeseItem> {
  @override
  List<SpaceCheeseItem>? getDataList(SpaceCheeseData response) {
    isEnd = response.page?.next == false;
    return response.items;
  }

  @override
  Future<LoadingState<SpaceCheeseData>> customGetData() => FavHttp.favPugv(
    account: Accounts.main,
    mid: Accounts.main.mid,
    page: page,
  );

  @override
  int? itemId(SpaceCheeseItem item) => item.seasonId;

  @override
  Future<LoadingState<void>> removeFavorite(int id, Account account) =>
      FavHttp.delFavPugv(id, account: account);
}
