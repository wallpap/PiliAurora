import 'package:pili_aurora/http/api.dart';

enum WebSsType {
  season(Api.seasonArchives),
  series(Api.seriesArchives),
  ;

  final String api;
  const WebSsType(this.api);
}
