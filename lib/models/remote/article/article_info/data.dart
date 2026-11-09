import 'package:pili_aurora/models/remote/article/article_info/stats.dart';
import 'package:pili_aurora/utils/extension/iterable_ext.dart';
import 'package:pili_aurora/utils/parse_bool.dart';

class ArticleInfoData {
  bool? like;
  bool? favorite;
  Stats? stats;
  String? title;
  List<String>? originImageUrls;

  ArticleInfoData({
    this.like,
    this.favorite,
    this.stats,
    this.title,
    this.originImageUrls,
  });

  factory ArticleInfoData.fromJson(Map<String, dynamic> json) =>
      ArticleInfoData(
        like: safeToBool(json['like']),
        favorite: json['favorite'] as bool?,
        stats: json['stats'] == null
            ? null
            : Stats.fromJson(json['stats'] as Map<String, dynamic>),
        title: json['title'] as String?,
        originImageUrls: (json['origin_image_urls'] as List?)?.fromCast(),
      );
}
