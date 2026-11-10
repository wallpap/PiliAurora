class UgcTriple {
  final bool like;
  final bool coin;
  final bool fav;
  final int multiply;

  UgcTriple({
    required this.like,
    required this.coin,
    required this.fav,
    required this.multiply,
  });

  factory UgcTriple.fromJson(Map<String, dynamic> json) {
    final multiply = json['multiply'];
    if (json['like'] is! bool ||
        json['coin'] is! bool ||
        json['fav'] is! bool ||
        (multiply != null &&
            (multiply is! int || multiply < 0 || multiply > 2)) ||
        (json['coin'] == true && multiply == null)) {
      throw const FormatException('三连回执缺少有效的互动状态或投币数量');
    }
    return UgcTriple(
      like: json['like'],
      coin: json['coin'],
      fav: json['fav'],
      multiply: multiply ?? 0,
    );
  }
}
