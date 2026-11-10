class VideoRelation {
  bool? attention;
  final bool favorite;
  bool? seasonFav;
  final bool like;
  final bool dislike;
  final int coin;

  VideoRelation({
    this.attention,
    required this.favorite,
    this.seasonFav,
    required this.like,
    required this.dislike,
    required this.coin,
  });

  factory VideoRelation.fromJson(Map<String, dynamic> json) {
    final coin = json['coin'];
    if (json['like'] is! bool ||
        json['favorite'] is! bool ||
        json['dislike'] is! bool ||
        coin is! num ||
        !coin.isFinite ||
        coin < 0 ||
        coin > 2 ||
        coin != coin.round()) {
      throw const FormatException('视频互动状态不完整');
    }
    return VideoRelation(
      attention: json['attention'] as bool?,
      favorite: json['favorite'] as bool,
      seasonFav: json['season_fav'] as bool?,
      like: json['like'] as bool,
      dislike: json['dislike'] as bool,
      coin: coin.toInt(),
    );
  }
}
