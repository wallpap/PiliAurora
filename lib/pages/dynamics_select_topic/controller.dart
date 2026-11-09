import 'package:pili_aurora/http/loading_state.dart';
import 'package:pili_aurora/http/search.dart';
import 'package:pili_aurora/models/remote/dynamic/dyn_topic_pub_search/data.dart';
import 'package:pili_aurora/models/remote/dynamic/dyn_topic_top/topic_item.dart';
import 'package:pili_aurora/pages/common/common_list_controller.dart';
import 'package:pili_aurora/utils/accounts.dart';
import 'package:flutter/widgets.dart';
import 'package:get/get.dart';

class SelectTopicController
    extends CommonListController<TopicPubSearchData, TopicItem> {
  final focusNode = FocusNode();
  final controller = TextEditingController();

  final RxBool enableClear = false.obs;

  @override
  Object get queryContext => Accounts.main;

  @override
  void onInit() {
    super.onInit();
    Accounts.mainChanges.addListener(_onAccountChanged);
    queryData();
  }

  void _onAccountChanged() => onReload();

  @override
  List<TopicItem>? getDataList(TopicPubSearchData response) {
    if (response.pageInfo?.hasMore == false) {
      isEnd = true;
    }
    return response.topicItems;
  }

  @override
  Future<LoadingState<TopicPubSearchData>> customGetData() =>
      SearchHttp.topicPubSearch(
        keywords: controller.text,
        pageNum: page,
      );

  @override
  void onClose() {
    Accounts.mainChanges.removeListener(_onAccountChanged);
    focusNode.dispose();
    controller.dispose();
    super.onClose();
  }
}
