class PopularSeriesListItem {
  final int number;
  String? name;

  PopularSeriesListItem({required this.number, this.name});

  factory PopularSeriesListItem.fromJson(Map<String, dynamic> json) {
    final number = json['number'];
    if (number is! int || number <= 0) {
      throw const FormatException('每周必看期数无效');
    }
    return PopularSeriesListItem(number: number, name: json['name'] as String?);
  }
}
