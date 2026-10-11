import 'package:pili_aurora/pages/about/diagnostics_page.dart';
import 'package:pili_aurora/common/widgets/flutter/list_tile.dart';
import 'package:pili_aurora/common/widgets/scaffold/simple_scaffold.dart';
import 'package:pili_aurora/common/widgets/view_safe_area.dart';
import 'package:pili_aurora/models/common/setting_type.dart';
import 'package:pili_aurora/pages/about/view.dart';
import 'package:pili_aurora/pages/setting/common_setting.dart';
import 'package:pili_aurora/pages/webdav/view.dart';
import 'package:pili_aurora/utils/extension/size_ext.dart';
import 'package:get/get.dart';
import 'package:material_design_icons_flutter/material_design_icons_flutter.dart';
import 'package:material_ui/material_ui.dart' hide ListTile;

class _SettingsModel {
  final SettingType type;
  final String? subtitle;
  final Icon icon;

  const _SettingsModel({
    required this.type,
    this.subtitle,
    required this.icon,
  });
}

class SettingPage extends StatefulWidget {
  const SettingPage({super.key});

  @override
  State<SettingPage> createState() => _SettingPageState();
}

class _SettingPageState extends State<SettingPage> {
  late SettingType _type = SettingType.styleSetting;
  late bool _isPortrait;
  late ThemeData theme;

  static const List<_SettingsModel> _items = [
    _SettingsModel(
      type: SettingType.styleSetting,
      subtitle: '主题与文字、布局与导航、图片与动效',
      icon: Icon(Icons.style_outlined),
    ),
    _SettingsModel(
      type: SettingType.recommendSetting,
      subtitle: '推荐来源（web/app）、刷新保留内容、过滤器',
      icon: Icon(Icons.explore_outlined),
    ),
    _SettingsModel(
      type: SettingType.contentSetting,
      subtitle: '搜索、评论、动态、视频详情与内容过滤',
      icon: Icon(Icons.forum_outlined),
    ),
    _SettingsModel(
      type: SettingType.videoSetting,
      subtitle: '画质、音质、解码、缓冲、音频输出等',
      icon: Icon(Icons.video_settings_outlined),
    ),
    _SettingsModel(
      type: SettingType.playSetting,
      subtitle: '播放行为、手势、全屏控件、弹幕与字幕',
      icon: Icon(Icons.touch_app_outlined),
    ),
    _SettingsModel(
      type: SettingType.privacySetting,
      subtitle: '切换账号、退出登录与黑名单',
      icon: Icon(Icons.privacy_tip_outlined),
    ),
    _SettingsModel(
      type: SettingType.extraSetting,
      subtitle: '网络连接、缓存与下载目录',
      icon: Icon(Icons.extension_outlined),
    ),
    _SettingsModel(
      type: SettingType.webdavSetting,
      subtitle: '导入导出设置与 WebDAV 同步',
      icon: Icon(MdiIcons.databaseCogOutline),
    ),
    _SettingsModel(
      type: SettingType.diagnosticSetting,
      subtitle: '异常与播放日志、性能记录、导出诊断包',
      icon: Icon(Icons.bug_report_outlined),
    ),
    _SettingsModel(
      type: SettingType.about,
      icon: Icon(Icons.info_outline),
    ),
  ];

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();

    theme = Theme.of(context);
    _isPortrait = MediaQuery.sizeOf(context).isPortrait;
  }

  @override
  Widget build(BuildContext context) {
    return SimpleScaffold(
      appBar: AppBar(
        title: _isPortrait ? const Text('设置') : Text(_type.title),
      ),
      body: ViewSafeArea(
        child: _isPortrait
            ? _buildList(theme)
            : Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    flex: 4,
                    child: _buildList(theme),
                  ),
                  VerticalDivider(
                    width: 1,
                    color: theme.colorScheme.outline.withValues(alpha: 0.1),
                  ),
                  Expanded(
                    flex: 6,
                    child: switch (_type) {
                      .privacySetting ||
                      .recommendSetting ||
                      .videoSetting ||
                      .playSetting ||
                      .styleSetting ||
                      .extraSetting ||
                      .contentSetting => CommonSetting(
                        settingType: _type,
                        showAppBar: false,
                      ),
                      .webdavSetting => const WebDavSettingPage(
                        showAppBar: false,
                      ),
                      .diagnosticSetting => const DiagnosticsPage(
                        showAppBar: false,
                      ),
                      .about => const AboutPage(showAppBar: false),
                    },
                  ),
                ],
              ),
      ),
    );
  }

  void _toPage(SettingType type) {
    if (_isPortrait) {
      Get.to(
        () => switch (type) {
          .privacySetting ||
          .recommendSetting ||
          .videoSetting ||
          .playSetting ||
          .styleSetting ||
          .extraSetting ||
          .contentSetting => CommonSetting(settingType: type),
          .webdavSetting => const WebDavSettingPage(),
          .diagnosticSetting => const DiagnosticsPage(),
          .about => const AboutPage(),
        },
      );
    } else {
      _type = type;
      setState(() {});
    }
  }

  Color? _getTileColor(ThemeData theme, SettingType type) {
    if (_isPortrait) {
      return null;
    } else {
      return type == _type ? theme.colorScheme.onInverseSurface : null;
    }
  }

  Widget _buildList(ThemeData theme) {
    final padding = MediaQuery.viewPaddingOf(context);
    TextStyle titleStyle = theme.textTheme.titleMedium!;
    TextStyle subTitleStyle = theme.textTheme.labelMedium!.copyWith(
      color: theme.colorScheme.outline,
    );
    return ListView(
      padding: EdgeInsets.only(bottom: padding.bottom + 100),
      children: [
        _buildSearchItem(theme),
        ..._items.map(
          (item) => ListTile(
            tileColor: _getTileColor(theme, item.type),
            onTap: () => _toPage(item.type),
            leading: item.icon,
            title: Text(item.type.title, style: titleStyle),
            subtitle: item.subtitle == null
                ? null
                : Text(item.subtitle!, style: subTitleStyle),
          ),
        ),
      ],
    );
  }

  Widget _buildSearchItem(ThemeData theme) => Padding(
    padding: const EdgeInsets.only(
      left: 16,
      right: 16,
      bottom: 8,
    ),
    child: Material(
      color: theme.colorScheme.onInverseSurface,
      borderRadius: const BorderRadius.all(Radius.circular(50)),
      child: InkWell(
        onTap: () => Get.toNamed('/settingsSearch'),
        borderRadius: const BorderRadius.all(Radius.circular(50)),
        child: const Padding(
          padding: EdgeInsets.symmetric(vertical: 8),
          child: Center(
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  size: 18,
                  applyTextScaling: true,
                  Icons.search,
                ),
                Text(
                  ' 搜索',
                  style: TextStyle(height: 1),
                  strutStyle: StrutStyle(height: 1, leading: 0),
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}
