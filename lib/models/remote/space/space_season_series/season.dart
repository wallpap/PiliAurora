import 'package:pili_aurora/models/remote/space/space_season_series/meta.dart';

class SpaceSsModel {
  SpaceSsMeta? meta;

  SpaceSsModel({this.meta});

  factory SpaceSsModel.fromJson(Map<String, dynamic> json) => SpaceSsModel(
    meta: json["meta"] == null ? null : SpaceSsMeta.fromJson(json["meta"]),
  );
}
