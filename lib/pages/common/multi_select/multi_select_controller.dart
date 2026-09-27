import 'package:pili_aurora/pages/common/common_list_controller.dart';
import 'package:pili_aurora/pages/common/multi_select/base.dart';

abstract class MultiSelectController<
  R,
  T extends MultiSelectData
> = CommonListController<R, T>
    with CommonMultiSelectMixin<T>, DeleteItemMixin;
