import 'package:pili_aurora/common/widgets/pair.dart';
import 'package:pili_aurora/services/logger.dart';
import 'package:pili_aurora/common/widgets/scaffold/simple_scaffold.dart';
import 'package:pili_aurora/http/constants.dart';
import 'package:pili_aurora/http/loading_state.dart';
import 'package:pili_aurora/http/sponsor_block.dart';
import 'package:pili_aurora/models/common/sponsor_block/segment_type.dart';
import 'package:pili_aurora/models/common/sponsor_block/skip_type.dart';
import 'package:pili_aurora/models/remote/sponsor_block/user_info.dart';
import 'package:pili_aurora/pages/setting/slide_color_picker.dart';
import 'package:pili_aurora/utils/accounts/account_manager/account_mgr.dart';
import 'package:pili_aurora/utils/filtering_text.dart';
import 'package:pili_aurora/utils/page_utils.dart';
import 'package:pili_aurora/utils/storage.dart';
import 'package:pili_aurora/utils/storage_key.dart';
import 'package:pili_aurora/utils/storage_pref.dart';
import 'package:pili_aurora/utils/utils.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart' show FilteringTextInputFormatter;
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:hive_ce/hive.dart';
import 'package:material_design_icons_flutter/material_design_icons_flutter.dart';
import 'package:material_ui/material_ui.dart';

class SponsorBlockPage extends StatefulWidget {
  const SponsorBlockPage({super.key});

  @override
  State<SponsorBlockPage> createState() => _SponsorBlockPageState();
}

class _SponsorBlockPageState extends State<SponsorBlockPage> {
  final _url = 'https://github.com/hanydd/BilibiliSponsorBlock';
  final _textController = TextEditingController();
  double _blockLimit = Pref.blockLimit;
  final _blockSettings = Pref.blockSettings;
  final List<Color> _blockColor = Pref.blockColor;
  String _userId = Pref.blockUserID;
  bool _blockToast = Pref.blockToast;
  String _blockServer = Pref.blockServer;
  bool _blockTrack = Pref.blockTrack;
  final _serverStatus = LoadingState<void>.loading().obs;
  final _userInfo = LoadingState<UserInfo>.loading().obs;
  int _statusVersion = 0;
  int _userVersion = 0;

  Box setting = GStorage.setting;
  final _saving = <String>{};

  Future<bool> _save(String key, Object value, VoidCallback apply) async {
    if (!_saving.add(key)) return false;
    try {
      await setting.put(key, value);
      if (key == SettingBoxKey.blockServer) {
        AccountManager.blockServer = value as String;
      }
      if (mounted) setState(apply);
      return true;
    } catch (error, stackTrace) {
      logger.w('空降助手设置保存失败', error: error.runtimeType, stackTrace: stackTrace);
      if (mounted) SmartDialog.showToast('设置保存失败，请重试');
      return false;
    } finally {
      _saving.remove(key);
    }
  }

  @override
  void initState() {
    super.initState();
    _checkServerStatus();
    _getUserInfo();
  }

  @override
  void dispose() {
    _textController.dispose();
    super.dispose();
  }

  Future<void> _checkServerStatus() async {
    final version = ++_statusVersion;
    final server = _blockServer;
    _serverStatus.value = LoadingState.loading();
    final result = await SponsorBlock.uptimeStatus();
    if (mounted && version == _statusVersion && server == _blockServer) {
      _serverStatus.value = result;
    }
  }

  Future<void> _getUserInfo() async {
    final version = ++_userVersion;
    final server = _blockServer;
    final userId = _userId;
    _userInfo.value = LoadingState.loading();
    final result = await SponsorBlock.userInfo(const [
      'viewCount',
      'minutesSaved',
      'segmentCount',
    ], userId: userId);
    if (mounted &&
        version == _userVersion &&
        server == _blockServer &&
        userId == _userId) {
      _userInfo.value = result;
    }
  }

  Widget _blockLimitItem(
    ThemeData theme,
    TextStyle titleStyle,
    TextStyle subTitleStyle,
  ) => Builder(
    builder: (context) {
      return ListTile(
        dense: true,
        onTap: () {
          _textController.text = _blockLimit.toString();
          showDialog(
            context: context,
            builder: (dialogContext) => AlertDialog(
              title: Text('最短片段时长', style: titleStyle),
              content: TextFormField(
                keyboardType: const .numberWithOptions(decimal: true),
                controller: _textController,
                autofocus: true,
                decoration: const InputDecoration(suffixText: 's'),
                inputFormatters: FilteringText.decimal,
              ),
              actions: [
                TextButton(
                  onPressed: Get.back,
                  child: Text(
                    '取消',
                    style: TextStyle(color: theme.colorScheme.outline),
                  ),
                ),
                TextButton(
                  onPressed: () async {
                    final value = double.tryParse(_textController.text);
                    if (value == null || !value.isFinite || value < 0) {
                      SmartDialog.showToast('请输入大于或等于 0 的有效秒数');
                      return;
                    }
                    final saved = await _save(
                      SettingBoxKey.blockLimit,
                      value,
                      () => _blockLimit = value,
                    );
                    if (saved &&
                        mounted &&
                        dialogContext.mounted &&
                        ModalRoute.of(dialogContext)?.isCurrent == true) {
                      Navigator.of(dialogContext).pop();
                    }
                  },
                  child: const Text('确定'),
                ),
              ],
            ),
          );
        },
        title: Text('最短片段时长', style: titleStyle),
        subtitle: Text(
          '忽略短于此时长的片段',
          style: subTitleStyle,
        ),
        trailing: Text(
          '${_blockLimit}s',
          style: const TextStyle(fontSize: 13),
        ),
      );
    },
  );

  Widget _aboutItem(TextStyle titleStyle, TextStyle subTitleStyle) => ListTile(
    dense: true,
    title: Text('关于空降助手', style: titleStyle),
    subtitle: Text(_url, style: subTitleStyle),
    onTap: () => PageUtils.launchURL(_url),
  );

  Widget _userIdItem(
    ThemeData theme,
    TextStyle titleStyle,
    TextStyle subTitleStyle,
  ) => Builder(
    builder: (context) {
      return ListTile(
        dense: true,
        title: Text('用户ID', style: titleStyle),
        subtitle: Text(_userId, style: subTitleStyle),
        onTap: () {
          final key = GlobalKey<FormFieldState<String>>();
          _textController.text = _userId;
          showDialog(
            context: context,
            builder: (dialogContext) {
              return AlertDialog(
                title: Text('用户ID', style: titleStyle),
                content: TextFormField(
                  key: key,
                  minLines: 1,
                  maxLines: 4,
                  autofocus: true,
                  controller: _textController,
                  inputFormatters: [
                    FilteringTextInputFormatter.allow(RegExp(r'[a-zA-Z\d]+')),
                  ],
                  decoration: const InputDecoration(errorMaxLines: 2),
                  validator: (value) {
                    if ((value?.length ?? -1) < 30) {
                      return '用户ID要求至少为30个字符长度的纯字符串';
                    }
                    return null;
                  },
                ),
                actions: [
                  TextButton(
                    onPressed: () async {
                      final value = Digest(
                        List.generate(16, (_) => Utils.random.nextInt(256)),
                      ).toString();

                      final saved = await _save(
                        SettingBoxKey.blockUserID,
                        value,
                        () => _userId = value,
                      );
                      if (saved && mounted) {
                        if (dialogContext.mounted &&
                            ModalRoute.of(dialogContext)?.isCurrent == true) {
                          Navigator.of(dialogContext).pop();
                        }
                        _getUserInfo();
                      }
                    },
                    child: const Text('随机'),
                  ),
                  TextButton(
                    onPressed: Get.back,
                    child: Text(
                      '取消',
                      style: TextStyle(
                        color: theme.colorScheme.outline,
                      ),
                    ),
                  ),
                  TextButton(
                    onPressed: () async {
                      if (key.currentState?.validate() != true) return;
                      final value = _textController.text;

                      final saved = await _save(
                        SettingBoxKey.blockUserID,
                        value,
                        () => _userId = value,
                      );
                      if (saved && mounted) {
                        if (dialogContext.mounted &&
                            ModalRoute.of(dialogContext)?.isCurrent == true) {
                          Navigator.of(dialogContext).pop();
                        }
                        _getUserInfo();
                      }
                    },
                    child: const Text('确定'),
                  ),
                ],
              );
            },
          );
        },
      );
    },
  );

  Widget _blockToastItem(TextStyle titleStyle) => Builder(
    builder: (context) {
      Future<void> update() async {
        final value = !_blockToast;
        await _save(SettingBoxKey.blockToast, value, () => _blockToast = value);
      }

      return ListTile(
        dense: true,
        onTap: update,
        title: Text(
          '显示跳过Toast',
          style: titleStyle,
        ),
        trailing: Transform.scale(
          alignment: Alignment.centerRight,
          scale: 0.8,
          child: Switch(
            value: _blockToast,
            onChanged: (val) => update(),
          ),
        ),
      );
    },
  );

  Widget _blockTrackItem(
    TextStyle titleStyle,
    TextStyle subTitleStyle,
  ) => Builder(
    builder: (context) {
      Future<void> update() async {
        final value = !_blockTrack;
        await _save(SettingBoxKey.blockTrack, value, () => _blockTrack = value);
      }

      return ListTile(
        dense: true,
        onTap: update,
        title: Text(
          '跳过次数统计跟踪',
          style: titleStyle,
        ),
        subtitle: Text(
          // from origin extension
          '此功能追踪您跳过了哪些片段，让用户知道他们提交的片段帮助了多少人。同时点赞会作为依据，确保垃圾信息不会污染数据库。在您每次跳过片段时，我们都会向服务器发送一条消息。希望大家开启此项设置，以便得到更准确的统计数据。:)',
          style: subTitleStyle,
        ),
        trailing: Transform.scale(
          alignment: Alignment.centerRight,
          scale: 0.8,
          child: Switch(
            value: _blockTrack,
            onChanged: (val) => update(),
          ),
        ),
      );
    },
  );

  Widget _blockUserInfo(
    ThemeData theme,
    TextStyle titleStyle,
    TextStyle subTitleStyle,
  ) => Obx(
    () {
      return ListTile(
        dense: true,
        onTap: _getUserInfo,
        title: Text(
          '您的信息',
          style: titleStyle,
        ),
        subtitle: switch (_userInfo.value) {
          Loading() => const SizedBox.shrink(),
          Success<UserInfo>(:final response) => Text(
            response.toString(),
            style: subTitleStyle,
          ),
          Error error => Text(
            error.toString(),
            style: subTitleStyle.copyWith(color: theme.colorScheme.error),
          ),
        },
      );
    },
  );

  Widget _blockServerItem(
    ThemeData theme,
    TextStyle titleStyle,
    TextStyle subTitleStyle,
  ) => Builder(
    builder: (context) {
      return ListTile(
        dense: true,
        onTap: () {
          _textController.text = _blockServer;
          showDialog(
            context: context,
            builder: (dialogContext) => AlertDialog(
              title: Text('服务器地址', style: titleStyle),
              content: TextFormField(
                keyboardType: TextInputType.url,
                controller: _textController,
                autofocus: true,
              ),
              actions: [
                TextButton(
                  onPressed: () async {
                    const value = HttpString.sponsorBlockBaseUrl;
                    final uri = Uri.tryParse(value);
                    if (uri == null ||
                        !const ['http', 'https'].contains(uri.scheme) ||
                        uri.host.isEmpty ||
                        uri.userInfo.isNotEmpty ||
                        uri.hasQuery ||
                        uri.hasFragment) {
                      SmartDialog.showToast('请输入有效的 HTTP 或 HTTPS 服务器地址');
                      return;
                    }
                    final saved = await _save(
                      SettingBoxKey.blockServer,
                      value,
                      () => _blockServer = value,
                    );
                    if (saved && mounted) {
                      if (dialogContext.mounted &&
                          ModalRoute.of(dialogContext)?.isCurrent == true) {
                        Navigator.of(dialogContext).pop();
                      }
                      _checkServerStatus();
                      _getUserInfo();
                    }
                  },
                  child: const Text('重置'),
                ),
                TextButton(
                  onPressed: Get.back,
                  child: Text(
                    '取消',
                    style: TextStyle(
                      color: theme.colorScheme.outline,
                    ),
                  ),
                ),
                TextButton(
                  onPressed: () async {
                    final value = _textController.text.trim();
                    final uri = Uri.tryParse(value);
                    if (uri == null ||
                        !const ['http', 'https'].contains(uri.scheme) ||
                        uri.host.isEmpty ||
                        uri.userInfo.isNotEmpty ||
                        uri.hasQuery ||
                        uri.hasFragment) {
                      SmartDialog.showToast('请输入有效的 HTTP 或 HTTPS 服务器地址');
                      return;
                    }
                    final saved = await _save(
                      SettingBoxKey.blockServer,
                      value,
                      () => _blockServer = value,
                    );
                    if (saved && mounted) {
                      if (dialogContext.mounted &&
                          ModalRoute.of(dialogContext)?.isCurrent == true) {
                        Navigator.of(dialogContext).pop();
                      }
                      _checkServerStatus();
                      _getUserInfo();
                    }
                  },
                  child: const Text('确定'),
                ),
              ],
            ),
          );
        },
        title: Text(
          '服务器地址',
          style: titleStyle,
        ),
        subtitle: Text(
          _blockServer,
          style: subTitleStyle,
        ),
      );
    },
  );

  Widget _serverStatusItem(ThemeData theme, TextStyle titleStyle) => Obx(
    () {
      String status;
      Color? color;
      switch (_serverStatus.value) {
        case Loading():
          status = '检查中';
        case Success():
          status = '正常';
          color = theme.colorScheme.primary;
        case Error error:
          status = error.toString();
          color = theme.colorScheme.error;
      }
      return ListTile(
        dense: true,
        onTap: _checkServerStatus,
        title: Text('服务器状态', style: titleStyle),
        trailing: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 250),
          child: Text(
            status,
            textAlign: TextAlign.end,
            style: TextStyle(fontSize: 13, color: color),
          ),
        ),
      );
    },
  );

  void onSelectColor(
    BuildContext context,
    int index,
    Color color,
    Pair<SegmentType, SkipType> item,
  ) {
    showDialog(
      context: context,
      builder: (dialogContext) => AlertDialog(
        clipBehavior: Clip.hardEdge,
        contentPadding: const EdgeInsets.symmetric(vertical: 16),
        title: Text.rich(
          TextSpan(
            children: [
              const TextSpan(
                text: 'Color Picker ',
                style: TextStyle(fontSize: 15),
              ),
              WidgetSpan(
                alignment: PlaceholderAlignment.middle,
                child: Container(
                  height: 10,
                  width: 10,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: color,
                  ),
                ),
                style: const TextStyle(fontSize: 13, height: 1),
              ),
              TextSpan(
                text: ' ${item.first.title}',
                style: const TextStyle(fontSize: 13, height: 1),
              ),
            ],
          ),
        ),
        content: SlideColorPicker(
          color: color,
          showResetBtn: true,
          onChanged: (Color? color) async {
            final colors = List<Color>.of(_blockColor);
            colors[index] = color ?? item.first.color;
            await _save(SettingBoxKey.blockColor, {
              for (final category in SegmentType.values)
                category.name: colors[category.index]
                    .toARGB32()
                    .toRadixString(16)
                    .padLeft(8, '0')
                    .substring(2),
            }, () => _blockColor[index] = colors[index]);
          },
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    const titleStyle = TextStyle(fontSize: 15);

    final subTitleStyle = TextStyle(
      fontSize: 13,
      color: theme.colorScheme.outline,
    );

    final divider = Divider(
      height: 1,
      color: theme.colorScheme.outline.withValues(alpha: 0.1),
    );

    final sliverDivider = SliverToBoxAdapter(child: divider);

    final dividerL = SliverToBoxAdapter(
      child: Divider(
        thickness: 16,
        color: theme.colorScheme.outline.withValues(alpha: 0.1),
      ),
    );

    return SimpleScaffold(
      appBar: AppBar(title: const Text('空降助手')),
      body: CustomScrollView(
        slivers: [
          dividerL,
          SliverToBoxAdapter(child: _serverStatusItem(theme, titleStyle)),
          dividerL,
          SliverToBoxAdapter(
            child: _blockLimitItem(theme, titleStyle, subTitleStyle),
          ),
          sliverDivider,
          SliverToBoxAdapter(child: _blockToastItem(titleStyle)),
          sliverDivider,
          SliverToBoxAdapter(child: _blockTrackItem(titleStyle, subTitleStyle)),
          sliverDivider,
          SliverToBoxAdapter(
            child: _blockUserInfo(theme, titleStyle, subTitleStyle),
          ),
          dividerL,
          SliverList.separated(
            itemCount: _blockSettings.length,
            itemBuilder: (context, index) =>
                _buildItem(theme, index, _blockSettings[index]),
            separatorBuilder: (context, index) => divider,
          ),
          dividerL,
          SliverToBoxAdapter(
            child: _userIdItem(theme, titleStyle, subTitleStyle),
          ),
          sliverDivider,
          SliverToBoxAdapter(
            child: _blockServerItem(theme, titleStyle, subTitleStyle),
          ),
          dividerL,
          SliverToBoxAdapter(child: _aboutItem(titleStyle, subTitleStyle)),
          dividerL,
          SliverToBoxAdapter(
            child: SizedBox(
              height: 55 + MediaQuery.viewPaddingOf(context).bottom,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildItem(
    ThemeData theme,
    int index,
    Pair<SegmentType, SkipType> item,
  ) {
    String behaviorLabel(SkipType type) => switch (type) {
      SkipType.alwaysSkip => '自动处理',
      SkipType.skipOnce => '处理一次',
      _ => type.label,
    };
    return Builder(
      builder: (context) {
        Color color = _blockColor[index];
        final isDisable = item.second == SkipType.disable;
        return ListTile(
          dense: true,
          enabled: item.second != SkipType.disable,
          onTap: () => onSelectColor(context, index, color, item),
          title: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text.rich(
                TextSpan(
                  children: [
                    WidgetSpan(
                      alignment: PlaceholderAlignment.middle,
                      child: Container(
                        height: 10,
                        width: 10,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: color,
                        ),
                      ),
                      style: const TextStyle(fontSize: 14, height: 1),
                    ),
                    TextSpan(
                      text: ' ${item.first.title}',
                      style: const TextStyle(fontSize: 14, height: 1),
                    ),
                  ],
                ),
              ),
              Builder(
                builder: (btnContext) {
                  return PopupMenuButton<SkipType>(
                    initialValue: item.second,
                    onSelected: (e) async {
                      await _save(SettingBoxKey.blockSettings, {
                        for (final entry in _blockSettings)
                          entry.first.name: identical(entry, item)
                              ? e.index
                              : entry.second.index,
                      }, () => item.second = e);
                    },
                    itemBuilder: (context) => SkipType.values
                        .map(
                          (type) => PopupMenuItem<SkipType>(
                            value: type,
                            child: Text(behaviorLabel(type)),
                          ),
                        )
                        .toList(),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      child: Text.rich(
                        style: TextStyle(
                          height: 1,
                          fontSize: 14,
                          color: isDisable
                              ? theme.colorScheme.outline.withValues(
                                  alpha: 0.7,
                                )
                              : theme.colorScheme.secondary,
                        ),
                        strutStyle: const StrutStyle(
                          height: 1,
                          leading: 0,
                          fontSize: 14,
                        ),
                        TextSpan(
                          children: [
                            TextSpan(text: behaviorLabel(item.second)),
                            WidgetSpan(
                              alignment: .middle,
                              child: Icon(
                                size: 14,
                                MdiIcons.unfoldMoreHorizontal,
                                color: isDisable
                                    ? theme.colorScheme.outline.withValues(
                                        alpha: 0.7,
                                      )
                                    : theme.colorScheme.secondary,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  );
                },
              ),
            ],
          ),
          subtitle: Text(
            item.first.description,
            style: TextStyle(
              fontSize: 12,
              color: isDisable ? null : theme.colorScheme.outline,
            ),
          ),
        );
      },
    );
  }
}
