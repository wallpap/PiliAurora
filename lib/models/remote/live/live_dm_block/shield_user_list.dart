class ShieldUserList {
  final int uid;
  final String uname;

  ShieldUserList({required this.uid, required this.uname});

  factory ShieldUserList.fromJson(Map<String, dynamic> json) {
    return ShieldUserList(
      uid: json['uid'] as int,
      uname: json['uname'] as String,
    );
  }
}
