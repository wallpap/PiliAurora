import 'package:pili_aurora/models/remote/live/live_area_list/area_item.dart';

class AreaList {
  final String? name;
  final List<AreaItem>? areaList;

  AreaList({this.name, List<AreaItem>? areaList})
    : areaList = areaList == null ? null : List.unmodifiable(areaList);

  factory AreaList.fromJson(Map<String, dynamic> json) => AreaList(
    name: json['name'] ?? '',
    areaList: (json['area_list'] as List<dynamic>?)
        ?.map((e) => AreaItem.fromJson(e as Map<String, dynamic>))
        .toList(),
  );
}
