import 'package:pili_aurora/models/remote/bubble/category_list.dart';

class Category {
  List<CategoryList>? categoryList;

  Category({this.categoryList});

  factory Category.fromJson(Map<String, dynamic> json) => Category(
    categoryList: (json['category_list'] as List<dynamic>?)
        ?.map((e) => CategoryList.fromJson(e as Map<String, dynamic>))
        .toList(),
  );
}
