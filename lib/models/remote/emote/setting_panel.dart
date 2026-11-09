import 'package:pili_aurora/models/remote/emote/package.dart';

class EmoteSettingPanel {
  final List<Package> userPanelPackages;
  final List<Package> allPackages;

  const EmoteSettingPanel({
    required this.userPanelPackages,
    required this.allPackages,
  });

  factory EmoteSettingPanel.fromJson(Map<String, dynamic> json) =>
      EmoteSettingPanel(
        userPanelPackages: _parsePackages(json['user_panel_packages']),
        allPackages: _parsePackages(json['all_packages']),
      );

  static List<Package> _parsePackages(Object? value) => (value as List? ?? [])
      .map((item) => Package.fromJson(item as Map<String, dynamic>))
      .toList();
}
